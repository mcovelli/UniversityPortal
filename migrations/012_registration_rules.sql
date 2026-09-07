-- =====================================================================
-- 012_registration_rules.sql
-- The add/drop window, the gates on a registration, and seat accounting.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 012_registration_rules.sql
--
-- Ships with edits to confirm_cart.php and drop_course.php. Applying one
-- without the other double-counts every seat -- see section 6.
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- Two of the four Student actions say "within a time frame", and until
-- now nothing in the system knew what the time frame was. All eleven
-- semesters carry an AddDropDeadline and not one line of PHP reads it.
--
-- The rest of this file closes gates that were either open or guarded in
-- one code path only:
--
--   holds          80 holds exist across FINANCIAL, HEALTH and ACADEMIC
--                  and none of them prevents anything. 57 students hold
--                  one and are registered anyway.
--   prerequisites  checked in confirm_cart.php, nowhere else. 13,464
--                  enrolments have one unmet -- counting PLANNED, which
--                  D1 makes live; the figure is 3,744 if you look only
--                  at ENROLLED and COMPLETED.
--   credit load    MaxCredits is never consulted. 1,634 student-semesters
--                  exceed it.
--   time clashes   1,256 students are booked into two rooms at once.
--   seats          decremented by PHP in a statement separate from the
--                  insert, with no floor. 625 sections hold more
--                  students than they have seats, one by 70.
--
-- ---------------------------------------------------------------------
-- WHAT "LIVE" MEANS  (decision D1: keep both vocabularies)
-- ---------------------------------------------------------------------
-- The data and the application disagree about this column. Every row in
-- FALL2023, FALL2024, SPRING2024 and SPRING2025 is PLANNED -- 15,429 of
-- them, in semesters that ended years ago -- while confirm_cart.php
-- writes ENROLLED or WAITLIST and drop_course.php writes DROPPED.
--
-- Rather than rewrite either side, both vocabularies count, which is
-- already what confirm_cart.php's own duplicate check assumes. Two
-- functions below make the distinction explicit:
--
--   nu_status_is_active   ENROLLED, IN-PROGRESS, PLANNED, WAITLIST
--                         -- a commitment of some kind exists
--   nu_status_holds_seat  ENROLLED, IN-PROGRESS, PLANNED
--                         -- occupies a chair; WAITLIST deliberately
--                            does not, since confirm_cart.php assigns
--                            it precisely when no chair is free
--
-- Clash and credit-load rules use holds_seat, not is_active: a waitlist
-- entry is not yet a place in a timetable.
--
-- ---------------------------------------------------------------------
-- THE OVERRIDE  (decision D3, defaulted)
-- ---------------------------------------------------------------------
-- Every rule in section 3 is policy, and an update-admin registers
-- students through the same code path a student uses. Each honours a
-- session variable:
--
--     SET @nu_override = 1;   -- this connection may bypass section 3
--
-- It is opt-in and per-connection: unset means enforce. No PHP sets it
-- yet, so today nothing bypasses anything. Wiring it to the admin role
-- is a deliberate act, not a default.
--
-- Seat accounting (section 4) and the referential rules in 010 ignore
-- the override. Skipping them would corrupt the count rather than relax
-- a policy.
-- =====================================================================

SET NAMES utf8mb4;


-- ---------------------------------------------------------------------
-- 1. Before -- the scale of what these rules will start refusing.
--    None of these rows is repaired here; a trigger governs new rows
--    only. They are listed so the numbers are on the record.
-- ---------------------------------------------------------------------
SELECT 'students holding a hold and a live enrolment' AS pre_existing, COUNT(DISTINCT sh.`StudentID`) AS rows_affected
  FROM `StudentHold` sh
  JOIN `StudentEnrollment` se ON se.`StudentID` = sh.`StudentID`
 WHERE se.`Status` IN ('ENROLLED','IN-PROGRESS','PLANNED','WAITLIST')
UNION ALL
SELECT 'enrolments with an unmet prerequisite', COUNT(*)
  FROM `StudentEnrollment` se
  JOIN `CoursePrerequisite` cp ON cp.`CourseID` = se.`CourseID`
 WHERE se.`Status` IN ('ENROLLED','IN-PROGRESS','PLANNED','COMPLETED')
   AND NOT EXISTS (SELECT 1 FROM `StudentEnrollment` pr
                    WHERE pr.`StudentID` = se.`StudentID`
                      AND pr.`CourseID`  = cp.`PrerequisiteCourseID`
                      AND pr.`Status`    = 'COMPLETED')
UNION ALL
SELECT 'student-semesters over MaxCredits', COUNT(*)
  FROM (SELECT se.`StudentID`, se.`SemesterID`,
               COALESCE(f.`MaxCredits`, p.`MaxCredits`,
                        fg.`MaxCredits`, pg.`MaxCredits`) AS max_credits,
               SUM(c.`Credits`) AS taken
          FROM `StudentEnrollment` se
          JOIN `Course` c ON c.`CourseID` = se.`CourseID`
          LEFT JOIN `FullTimeUG`   f  ON f.`StudentID`  = se.`StudentID`
          LEFT JOIN `PartTimeUG`   p  ON p.`StudentID`  = se.`StudentID`
          LEFT JOIN `FullTimeGrad` fg ON fg.`StudentID` = se.`StudentID`
          LEFT JOIN `PartTimeGrad` pg ON pg.`StudentID` = se.`StudentID`
         WHERE se.`Status` IN ('ENROLLED','IN-PROGRESS','PLANNED')
         GROUP BY se.`StudentID`, se.`SemesterID`, max_credits) x
 WHERE x.max_credits IS NOT NULL AND x.taken > x.max_credits
UNION ALL
SELECT 'students double-booked in one timeslot', COUNT(*)
  FROM (SELECT se.`StudentID`
          FROM `StudentEnrollment` se
          JOIN `CourseSection` cs ON cs.`CRN` = se.`CRN`
         WHERE se.`Status` IN ('ENROLLED','IN-PROGRESS','PLANNED')
           AND cs.`TimeSlotID` IS NOT NULL
         GROUP BY se.`StudentID`, cs.`TimeSlotID`, se.`SemesterID`
        HAVING COUNT(*) > 1) y
UNION ALL
SELECT 'sections already below zero seats', COUNT(*)
  FROM `CourseSection` WHERE `AvailableSeats` < 0;


-- ---------------------------------------------------------------------
-- 2. What counts as live
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS `nu_status_is_active`;
DROP FUNCTION IF EXISTS `nu_status_holds_seat`;
DELIMITER $$

CREATE FUNCTION `nu_status_is_active`(p_status VARCHAR(16)
        CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci)
RETURNS TINYINT
DETERMINISTIC
BEGIN
  RETURN p_status IN ('ENROLLED','IN-PROGRESS','PLANNED','WAITLIST');
END$$

CREATE FUNCTION `nu_status_holds_seat`(p_status VARCHAR(16)
        CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci)
RETURNS TINYINT
DETERMINISTIC
BEGIN
  RETURN p_status IN ('ENROLLED','IN-PROGRESS','PLANNED');
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 3. The gates on a registration
--
-- All seven are BEFORE INSERT on StudentEnrollment and all read
-- NEW.CourseID and NEW.SemesterID, which trg_SE_before_insert_denorm
-- (migration 010) rewrites from the section. FOLLOWS chains them behind
-- it, so none of them can end up reading the caller's values instead.
-- ---------------------------------------------------------------------

-- T1 -- the add/drop window
--
-- Opens 90 days before the semester starts, which is the window
-- registration_semesters.php already applies when it decides which
-- semesters to offer; closes at AddDropDeadline, which nothing has ever
-- read. A semester with no deadline set is left unguarded rather than
-- closed, so an unconfigured term fails open.
DROP TRIGGER IF EXISTS `trg_SE_before_insert_window`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_window`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_denorm`
BEGIN
  DECLARE v_deadline DATETIME;
  DECLARE v_start    DATE;

  IF COALESCE(@nu_override, 0) <> 1 AND `nu_status_is_active`(NEW.`Status`) THEN
    SELECT s.`AddDropDeadline`, s.`StartDate`
      INTO v_deadline, v_start
      FROM `Semester` s WHERE s.`SemesterID` = NEW.`SemesterID`;

    IF v_deadline IS NOT NULL AND NOW() > v_deadline THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'The add/drop period for that semester has closed.';
    END IF;

    IF v_start IS NOT NULL AND NOW() < DATE_SUB(v_start, INTERVAL 90 DAY) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Registration for that semester has not opened yet.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- T3 -- a hold blocks registration
DROP TRIGGER IF EXISTS `trg_SE_before_insert_hold`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_hold`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_window`
BEGIN
  DECLARE v_types VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

  IF COALESCE(@nu_override, 0) <> 1 AND `nu_status_is_active`(NEW.`Status`) THEN
    SELECT GROUP_CONCAT(DISTINCT h.`HoldType` ORDER BY h.`HoldType` SEPARATOR ', ')
      INTO v_types
      FROM `StudentHold` sh
      JOIN `Hold` h ON h.`HoldID` = sh.`HoldID`
     WHERE sh.`StudentID` = NEW.`StudentID`;

    IF v_types IS NOT NULL THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Registration is blocked by a hold on this account.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- T4 -- prerequisites, at the grade the prerequisite demands
--
-- The same rule confirm_cart.php applies, moved where every path meets
-- it. 13,464 existing rows break it and are untouched: they were loaded
-- straight into the table, never through the cart.
DROP TRIGGER IF EXISTS `trg_SE_before_insert_prereq`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_prereq`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_hold`
BEGIN
  DECLARE v_missing VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

  IF COALESCE(@nu_override, 0) <> 1 AND `nu_status_is_active`(NEW.`Status`) THEN
    SELECT GROUP_CONCAT(cp.`PrerequisiteCourseID` ORDER BY cp.`PrerequisiteCourseID` SEPARATOR ', ')
      INTO v_missing
      FROM `CoursePrerequisite` cp
     WHERE cp.`CourseID` = NEW.`CourseID`
       AND NOT EXISTS (
             SELECT 1
               FROM `StudentEnrollment` pr
               JOIN `GradingScale` got ON got.`GradeLetter` = pr.`Grade`
               JOIN `GradingScale` req ON req.`GradeLetter` = cp.`MinGradeRequired`
              WHERE pr.`StudentID` = NEW.`StudentID`
                AND pr.`CourseID`  = cp.`PrerequisiteCourseID`
                AND pr.`Status`    = 'COMPLETED'
                AND got.`GradeValue` >= req.`GradeValue`);

    IF v_missing IS NOT NULL THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'A prerequisite for that course has not been completed.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- T5 -- the semester credit ceiling
--
-- MaxCredits comes from whichever of the four load tables holds the
-- student. A student in none of them is unconstrained rather than
-- blocked.
DROP TRIGGER IF EXISTS `trg_SE_before_insert_creditload`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_creditload`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_prereq`
BEGIN
  DECLARE v_max     INT DEFAULT NULL;
  DECLARE v_current INT DEFAULT 0;
  DECLARE v_adding  INT DEFAULT 0;

  IF COALESCE(@nu_override, 0) <> 1 AND `nu_status_holds_seat`(NEW.`Status`) THEN

    SELECT COALESCE(f.`MaxCredits`, p.`MaxCredits`, fg.`MaxCredits`, pg.`MaxCredits`)
      INTO v_max
      FROM `Student` s
      LEFT JOIN `FullTimeUG`   f  ON f.`StudentID`  = s.`StudentID`
      LEFT JOIN `PartTimeUG`   p  ON p.`StudentID`  = s.`StudentID`
      LEFT JOIN `FullTimeGrad` fg ON fg.`StudentID` = s.`StudentID`
      LEFT JOIN `PartTimeGrad` pg ON pg.`StudentID` = s.`StudentID`
     WHERE s.`StudentID` = NEW.`StudentID`;

    IF v_max IS NOT NULL THEN
      SELECT COALESCE(SUM(c.`Credits`), 0)
        INTO v_current
        FROM `StudentEnrollment` se
        JOIN `Course` c ON c.`CourseID` = se.`CourseID`
       WHERE se.`StudentID`  = NEW.`StudentID`
         AND se.`SemesterID` = NEW.`SemesterID`
         AND `nu_status_holds_seat`(se.`Status`);

      SELECT COALESCE(c.`Credits`, 0) INTO v_adding
        FROM `Course` c WHERE c.`CourseID` = NEW.`CourseID`;

      IF v_current + v_adding > v_max THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'That course would put the student over their credit limit for the semester.';
      END IF;
    END IF;
  END IF;
END$$
DELIMITER ;


-- T7 -- no two sections in the same timeslot
DROP TRIGGER IF EXISTS `trg_SE_before_insert_timeclash`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_timeclash`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_creditload`
BEGIN
  DECLARE v_slot INT DEFAULT NULL;

  IF COALESCE(@nu_override, 0) <> 1 AND `nu_status_holds_seat`(NEW.`Status`) THEN
    SELECT cs.`TimeSlotID` INTO v_slot
      FROM `CourseSection` cs WHERE cs.`CRN` = NEW.`CRN`;

    IF v_slot IS NOT NULL
       AND EXISTS (SELECT 1
                     FROM `StudentEnrollment` se
                     JOIN `CourseSection` cs2 ON cs2.`CRN` = se.`CRN`
                    WHERE se.`StudentID`  = NEW.`StudentID`
                      AND se.`SemesterID` = NEW.`SemesterID`
                      AND se.`CRN`       <> NEW.`CRN`
                      AND cs2.`TimeSlotID` = v_slot
                      AND `nu_status_holds_seat`(se.`Status`)) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'That section clashes with another course this semester.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- T2 -- the drop window
--
-- A drop is an UPDATE to DROPPED, not a DELETE, so this is separate from
-- T1 rather than a branch of it.
DROP TRIGGER IF EXISTS `trg_SE_before_update_dropwindow`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_update_dropwindow`
BEFORE UPDATE ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_update_denorm`
BEGIN
  DECLARE v_deadline DATETIME;

  IF COALESCE(@nu_override, 0) <> 1
     AND NEW.`Status` = 'DROPPED' AND OLD.`Status` <> 'DROPPED' THEN

    SELECT s.`AddDropDeadline` INTO v_deadline
      FROM `Semester` s WHERE s.`SemesterID` = NEW.`SemesterID`;

    IF v_deadline IS NOT NULL AND NOW() > v_deadline THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'The add/drop period for that semester has closed.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 4. Seat accounting
--
-- The count moves into the same transaction as the enrolment, which is
-- what makes it correct: confirm_cart.php read the seat count, decided a
-- status, inserted, then decremented in a separate statement, so two
-- students registering at once could both see the last chair.
--
-- These ignore @nu_override. An override relaxes a policy; it must not
-- desynchronise a count.
-- ---------------------------------------------------------------------

-- Refuse a seat-taking enrolment into a full section, with a message
-- that says so. Without this the insert still fails -- the decrement
-- below would drive the count negative and section 5 would reject it --
-- but the error would talk about seat counts instead of a full class.
DROP TRIGGER IF EXISTS `trg_SE_before_insert_capacity`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_capacity`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_timeclash`
BEGIN
  DECLARE v_seats INT DEFAULT NULL;

  IF `nu_status_holds_seat`(NEW.`Status`) THEN
    SELECT cs.`AvailableSeats` INTO v_seats
      FROM `CourseSection` cs WHERE cs.`CRN` = NEW.`CRN`;

    IF v_seats IS NOT NULL AND v_seats <= 0 THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'That section is full. Waitlist instead.';
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_SE_after_insert_seats`$$
CREATE TRIGGER `trg_SE_after_insert_seats`
AFTER INSERT ON `StudentEnrollment` FOR EACH ROW
BEGIN
  IF `nu_status_holds_seat`(NEW.`Status`) THEN
    UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` - 1
     WHERE `CRN` = NEW.`CRN`;
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_SE_after_update_seats`$$
CREATE TRIGGER `trg_SE_after_update_seats`
AFTER UPDATE ON `StudentEnrollment` FOR EACH ROW
BEGIN
  DECLARE v_was TINYINT DEFAULT `nu_status_holds_seat`(OLD.`Status`);
  DECLARE v_is  TINYINT DEFAULT `nu_status_holds_seat`(NEW.`Status`);

  IF OLD.`CRN` <> NEW.`CRN` THEN
    -- moved between sections: settle both sides
    IF v_was THEN
      UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` + 1 WHERE `CRN` = OLD.`CRN`;
    END IF;
    IF v_is THEN
      UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` - 1 WHERE `CRN` = NEW.`CRN`;
    END IF;
  ELSE
    IF v_was AND NOT v_is THEN
      UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` + 1 WHERE `CRN` = NEW.`CRN`;
    ELSEIF v_is AND NOT v_was THEN
      UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` - 1 WHERE `CRN` = NEW.`CRN`;
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_SE_after_delete_seats`$$
CREATE TRIGGER `trg_SE_after_delete_seats`
AFTER DELETE ON `StudentEnrollment` FOR EACH ROW
BEGIN
  IF `nu_status_holds_seat`(OLD.`Status`) THEN
    UPDATE `CourseSection` SET `AvailableSeats` = `AvailableSeats` + 1
     WHERE `CRN` = OLD.`CRN`;
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. T12 -- the seat floor
--
-- A CHECK (AvailableSeats >= 0) would be cheaper, but 41 sections are
-- already negative and a check constraint would make those rows
-- unupdatable -- including the drop that would bring them back toward
-- zero. So the rule is "do not make it worse": a decrement below zero is
-- refused, an increment is always allowed.
--
-- Investigation showed those 41 are not corruption. AvailableSeats plus
-- live enrolments comes to exactly 40 on every one of them, so the
-- counter was decrementing correctly and the sections were genuinely
-- oversold -- 110 students in a 40-seat room on the worst. Nothing here
-- rewrites them; they recover one seat per drop.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_CS_before_update_seatfloor`;
DELIMITER $$
CREATE TRIGGER `trg_CS_before_update_seatfloor`
BEFORE UPDATE ON `CourseSection` FOR EACH ROW
BEGIN
  IF NEW.`AvailableSeats` IS NOT NULL
     AND NEW.`AvailableSeats` < 0
     AND NEW.`AvailableSeats` < COALESCE(OLD.`AvailableSeats`, 0) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That section has no seats left.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 6. The PHP that must change with this
-- ---------------------------------------------------------------------
-- confirm_cart.php  -- drop its "UPDATE CourseSection SET AvailableSeats
--                      = AvailableSeats - 1". trg_SE_after_insert_seats
--                      does it now, atomically. Leaving both in place
--                      charges two seats for one registration.
--
-- drop_course.php   -- drop its matching "+ 1" for the same reason.
--
-- Both files are updated in the same commit as this migration.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 7. After
-- ---------------------------------------------------------------------
SELECT `TRIGGER_NAME`, `EVENT_MANIPULATION`, `ACTION_ORDER`
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE()
   AND `EVENT_OBJECT_TABLE` IN ('StudentEnrollment','CourseSection')
 ORDER BY `EVENT_OBJECT_TABLE`, `EVENT_MANIPULATION`, `ACTION_ORDER`;

SELECT COUNT(*) AS trigger_count_expect_29
  FROM information_schema.`TRIGGERS` WHERE `TRIGGER_SCHEMA` = DATABASE();
