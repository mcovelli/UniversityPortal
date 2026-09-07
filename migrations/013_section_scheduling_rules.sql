-- =====================================================================
-- 013_section_scheduling_rules.sql
-- Closes the three constraints D4 left open: no negative seats, no
-- room double-booked in the same timeslot, no faculty double-booked
-- in the same timeslot.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 013_section_scheduling_rules.sql
--
-- No PHP changes ship with this one.
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- migrations/README.md flagged three rules that a real constraint could
-- enforce, but couldn't be added outright: 41 sections already read
-- negative, 52 room/timeslot/semester triples already repeat, and 131
-- faculty/timeslot/semester triples already repeat.
--
-- The three don't get the same fix, because they aren't the same kind
-- of fact.
--
-- AvailableSeats is a live counter, not a record of anything that
-- happened. Migration 012 already proved it: AvailableSeats plus live
-- enrolments comes to exactly the true capacity on every one of those
-- 41 rows, and the seat-floor trigger from 012 guarantees they climb
-- back to zero on their own as students drop. Flooring them to zero
-- here doesn't rewrite history -- it's the value they were already
-- headed for. That makes a real CHECK safe to add.
--
-- A room or faculty double-booking is a historical scheduling record:
-- which room, which instructor, which semester. There's no way to tell,
-- from the data alone, which of two clashing sections was the mistake --
-- reassigning one to make a constraint pass would be inventing a fact
-- with no basis, the same trap section 5 of migration 011 declined for
-- the 312 students with a major and no declaration. So these become
-- triggers, not constraints: reject a *new* clash, leave the 183
-- existing ones alone. Same posture as every rule in 010-012.
--
-- Both new triggers honour @nu_override, same as the 012 rules -- an
-- UpdateAdmin correcting a schedule can still create a deliberate
-- overlap.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 1. Before -- the scale of what this closes
-- ---------------------------------------------------------------------
SELECT 'sections with AvailableSeats < 0' AS check_name, COUNT(*) AS n
  FROM `CourseSection` WHERE `AvailableSeats` < 0
UNION ALL
SELECT 'room/timeslot/semester triples with >1 section', COUNT(*)
  FROM (SELECT 1 FROM `CourseSection`
         WHERE `RoomID` IS NOT NULL AND `TimeSlotID` IS NOT NULL AND `SemesterID` IS NOT NULL
         GROUP BY `RoomID`, `TimeSlotID`, `SemesterID` HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'faculty/timeslot/semester triples with >1 section', COUNT(*)
  FROM (SELECT 1 FROM `CourseSection`
         WHERE `FacultyID` IS NOT NULL AND `TimeSlotID` IS NOT NULL AND `SemesterID` IS NOT NULL
         GROUP BY `FacultyID`, `TimeSlotID`, `SemesterID` HAVING COUNT(*) > 1) t;


-- ---------------------------------------------------------------------
-- 2. Seat floor -- repair, then a real constraint
-- ---------------------------------------------------------------------
-- The repair fires the existing trg_CS_before_update_seatfloor trigger
-- (BEFORE UPDATE), but that trigger only rejects a move that goes lower
-- than it already was -- 0 is never lower, so it never blocks this.
-- ---------------------------------------------------------------------
UPDATE `CourseSection` SET `AvailableSeats` = 0 WHERE `AvailableSeats` < 0;

ALTER TABLE `CourseSection`
  ADD CONSTRAINT `chk_CourseSection_seats` CHECK (`AvailableSeats` IS NULL OR `AvailableSeats` >= 0);


-- ---------------------------------------------------------------------
-- 3. Room clash -- reject a new double-booking, leave the 52 alone
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_CS_before_insert_roomclash`;
DELIMITER $$
CREATE TRIGGER `trg_CS_before_insert_roomclash`
BEFORE INSERT ON `CourseSection` FOR EACH ROW
BEGIN
  IF COALESCE(@nu_override, 0) <> 1
     AND NEW.`RoomID` IS NOT NULL AND NEW.`TimeSlotID` IS NOT NULL AND NEW.`SemesterID` IS NOT NULL
     AND EXISTS (SELECT 1 FROM `CourseSection` cs
                  WHERE cs.`RoomID` = NEW.`RoomID`
                    AND cs.`TimeSlotID` = NEW.`TimeSlotID`
                    AND cs.`SemesterID` = NEW.`SemesterID`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That room is already booked for that timeslot and semester.';
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS `trg_CS_before_update_roomclash`;
DELIMITER $$
CREATE TRIGGER `trg_CS_before_update_roomclash`
BEFORE UPDATE ON `CourseSection` FOR EACH ROW
BEGIN
  IF COALESCE(@nu_override, 0) <> 1
     AND NEW.`RoomID` IS NOT NULL AND NEW.`TimeSlotID` IS NOT NULL AND NEW.`SemesterID` IS NOT NULL
     AND EXISTS (SELECT 1 FROM `CourseSection` cs
                  WHERE cs.`RoomID` = NEW.`RoomID`
                    AND cs.`TimeSlotID` = NEW.`TimeSlotID`
                    AND cs.`SemesterID` = NEW.`SemesterID`
                    AND cs.`CRN` <> NEW.`CRN`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That room is already booked for that timeslot and semester.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 4. Faculty clash -- reject a new double-booking, leave the 131 alone
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_CS_before_insert_facultyclash`;
DELIMITER $$
CREATE TRIGGER `trg_CS_before_insert_facultyclash`
BEFORE INSERT ON `CourseSection` FOR EACH ROW
BEGIN
  IF COALESCE(@nu_override, 0) <> 1
     AND NEW.`FacultyID` IS NOT NULL AND NEW.`TimeSlotID` IS NOT NULL AND NEW.`SemesterID` IS NOT NULL
     AND EXISTS (SELECT 1 FROM `CourseSection` cs
                  WHERE cs.`FacultyID` = NEW.`FacultyID`
                    AND cs.`TimeSlotID` = NEW.`TimeSlotID`
                    AND cs.`SemesterID` = NEW.`SemesterID`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That faculty member already teaches another section in that timeslot and semester.';
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS `trg_CS_before_update_facultyclash`;
DELIMITER $$
CREATE TRIGGER `trg_CS_before_update_facultyclash`
BEFORE UPDATE ON `CourseSection` FOR EACH ROW
BEGIN
  IF COALESCE(@nu_override, 0) <> 1
     AND NEW.`FacultyID` IS NOT NULL AND NEW.`TimeSlotID` IS NOT NULL AND NEW.`SemesterID` IS NOT NULL
     AND EXISTS (SELECT 1 FROM `CourseSection` cs
                  WHERE cs.`FacultyID` = NEW.`FacultyID`
                    AND cs.`TimeSlotID` = NEW.`TimeSlotID`
                    AND cs.`SemesterID` = NEW.`SemesterID`
                    AND cs.`CRN` <> NEW.`CRN`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That faculty member already teaches another section in that timeslot and semester.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. After
-- ---------------------------------------------------------------------
SELECT `TRIGGER_NAME`, `EVENT_MANIPULATION`, `ACTION_ORDER`
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE() AND `EVENT_OBJECT_TABLE` = 'CourseSection'
 ORDER BY `EVENT_MANIPULATION`, `ACTION_ORDER`;

SELECT COUNT(*) AS trigger_count_expect_33
  FROM information_schema.`TRIGGERS` WHERE `TRIGGER_SCHEMA` = DATABASE();

SELECT COUNT(*) AS negative_seats_expect_0
  FROM `CourseSection` WHERE `AvailableSeats` < 0;
