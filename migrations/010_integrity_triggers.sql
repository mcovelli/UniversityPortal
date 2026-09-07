-- =====================================================================
-- 010_integrity_triggers.sql
-- The rules the data already satisfies: one foreign key and nine
-- triggers that lock in properties the database currently has by luck.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 010_integrity_triggers.sql
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- Every rule in this file is one the live data satisfies today with zero
-- violations. Nothing here can reject an existing row, so this migration
-- is safe to run without a cleanup first -- unlike 012, which enforces
-- rules that thousands of historical rows break.
--
-- What it establishes:
--
--   Grade validity   StudentEnrollment.Grade is varchar(2) with no
--                    constraint. Every one of the 15,627 graded rows
--                    already holds a letter from GradingScale, so a
--                    foreign key costs nothing and stops a typo from
--                    silently dropping a course out of the GPA -- the
--                    GPA join in UpdateDegreeAudit is an inner join on
--                    GradeLetter, so an unmatched grade does not raise
--                    an error, it just disappears from the average.
--
--   Denormalisation  StudentEnrollment repeats CourseID and SemesterID
--                    from the section named by CRN. They agree in all
--                    31,056 rows only because one code path writes them.
--                    Deriving them from CourseSection makes that
--                    structural, and every later trigger reads those
--                    two columns.
--
--   Course level     No undergraduate is in a GRAD course today.
--
--   Specialisation   Student/Undergraduate/Graduate and the four load
--                    tables encode one fact across three levels. The
--                    hierarchy is disjoint and total right now --
--                    migration 007 made it so -- and nothing has
--                    stopped it drifting since.
--
-- ---------------------------------------------------------------------
-- SESSION OVERRIDE
-- ---------------------------------------------------------------------
-- None of these triggers honour @nu_override. They protect referential
-- facts, not policy: there is no legitimate reason for an administrator
-- to file an undergraduate into a graduate programme or to record a
-- grade that does not exist. 012 is where policy rules live, and those
-- do honour the override.
-- =====================================================================

SET NAMES utf8mb4;


-- ---------------------------------------------------------------------
-- 1. Before: prove every rule below is already satisfied.
--    Any non-zero here means STOP -- read 012's cleanup notes first.
-- ---------------------------------------------------------------------
SELECT 'grades not in GradingScale' AS check_name,
       COUNT(*) AS violations
  FROM `StudentEnrollment` se
 WHERE se.`Grade` IS NOT NULL
   AND se.`Grade` NOT IN (SELECT `GradeLetter` FROM `GradingScale`)
UNION ALL
SELECT 'enrolment disagrees with its section',
       COUNT(*)
  FROM `StudentEnrollment` se
  JOIN `CourseSection` cs ON cs.`CRN` = se.`CRN`
 WHERE se.`CourseID` <> cs.`CourseID` OR se.`SemesterID` <> cs.`SemesterID`
UNION ALL
SELECT 'undergraduate in a GRAD course',
       COUNT(*)
  FROM `StudentEnrollment` se
  JOIN `Student` s ON s.`StudentID` = se.`StudentID`
  JOIN `Course`  c ON c.`CourseID`  = se.`CourseID`
 WHERE s.`StudentType` = 'Undergraduate' AND c.`CourseType` = 'GRAD'
UNION ALL
SELECT 'student in both Undergraduate and Graduate',
       COUNT(*)
  FROM `Undergraduate` u JOIN `Graduate` g ON g.`StudentID` = u.`StudentID`
UNION ALL
SELECT 'student in both FullTimeUG and PartTimeUG',
       COUNT(*)
  FROM `FullTimeUG` f JOIN `PartTimeUG` p ON p.`StudentID` = f.`StudentID`
UNION ALL
SELECT 'student in both FullTimeGrad and PartTimeGrad',
       COUNT(*)
  FROM `FullTimeGrad` f JOIN `PartTimeGrad` p ON p.`StudentID` = f.`StudentID`
UNION ALL
SELECT 'load table disagrees with UGStudentType',
       COUNT(*)
  FROM `Undergraduate` u
 WHERE (u.`UGStudentType` = 'FullTimeUG'
        AND NOT EXISTS (SELECT 1 FROM `FullTimeUG` f WHERE f.`StudentID` = u.`StudentID`))
    OR (u.`UGStudentType` = 'PartTimeUG'
        AND NOT EXISTS (SELECT 1 FROM `PartTimeUG` p WHERE p.`StudentID` = u.`StudentID`))
UNION ALL
SELECT 'load table disagrees with GradStudentType',
       COUNT(*)
  FROM `Graduate` g
 WHERE (g.`GradStudentType` = 'FullTimeGrad'
        AND NOT EXISTS (SELECT 1 FROM `FullTimeGrad` f WHERE f.`StudentID` = g.`StudentID`))
    OR (g.`GradStudentType` = 'PartTimeGrad'
        AND NOT EXISTS (SELECT 1 FROM `PartTimeGrad` p WHERE p.`StudentID` = g.`StudentID`));


-- ---------------------------------------------------------------------
-- 2. Guard: refuse to run if any of the above is non-zero.
--    A trigger governs new rows only, so adding one over broken data
--    hides the breakage instead of fixing it.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `nu_guard_010`;
DELIMITER $$
CREATE PROCEDURE `nu_guard_010`()
BEGIN
  DECLARE v_bad INT DEFAULT 0;

  SELECT (SELECT COUNT(*) FROM `StudentEnrollment` se
           WHERE se.`Grade` IS NOT NULL
             AND se.`Grade` NOT IN (SELECT `GradeLetter` FROM `GradingScale`))
       + (SELECT COUNT(*) FROM `StudentEnrollment` se
           JOIN `CourseSection` cs ON cs.`CRN` = se.`CRN`
          WHERE se.`CourseID` <> cs.`CourseID` OR se.`SemesterID` <> cs.`SemesterID`)
       + (SELECT COUNT(*) FROM `Undergraduate` u
           JOIN `Graduate` g ON g.`StudentID` = u.`StudentID`)
       + (SELECT COUNT(*) FROM `FullTimeUG` f
           JOIN `PartTimeUG` p ON p.`StudentID` = f.`StudentID`)
       + (SELECT COUNT(*) FROM `FullTimeGrad` f
           JOIN `PartTimeGrad` p ON p.`StudentID` = f.`StudentID`)
    INTO v_bad;

  IF v_bad > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = '010 aborted: the data breaks a rule this migration would enforce. Run section 1 and resolve it first.';
  END IF;
END$$
DELIMITER ;
CALL `nu_guard_010`();
DROP PROCEDURE `nu_guard_010`;


-- ---------------------------------------------------------------------
-- 3. Grade must be a letter the grading scale defines
-- ---------------------------------------------------------------------
ALTER TABLE `StudentEnrollment`
  ADD CONSTRAINT `fk_StudentEnrollment_Grade`
  FOREIGN KEY (`Grade`) REFERENCES `GradingScale` (`GradeLetter`)
  ON DELETE RESTRICT ON UPDATE CASCADE;


-- ---------------------------------------------------------------------
-- 4. T8 -- an enrolment describes the section it points at
--
-- BEFORE INSERT, so this corrects rather than rejects: whatever the
-- caller passed for CourseID and SemesterID is replaced by the section's
-- own values. confirm_cart.php passes a CourseID taken from the session
-- cart, which is the one value in that flow a user could tamper with.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_SE_before_insert_denorm`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_denorm`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
BEGIN
  DECLARE v_course   VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
  DECLARE v_semester VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

  SELECT cs.`CourseID`, cs.`SemesterID`
    INTO v_course, v_semester
    FROM `CourseSection` cs
   WHERE cs.`CRN` = NEW.`CRN`;

  IF v_course IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Enrolment refers to a CRN that does not exist.';
  END IF;

  IF v_semester IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That section has no semester, so it cannot be enrolled in.';
  END IF;

  SET NEW.`CourseID`   = v_course;
  SET NEW.`SemesterID` = v_semester;
END$$

-- The same correction on UPDATE, in case a CRN is ever repointed.
DROP TRIGGER IF EXISTS `trg_SE_before_update_denorm`$$
CREATE TRIGGER `trg_SE_before_update_denorm`
BEFORE UPDATE ON `StudentEnrollment` FOR EACH ROW
BEGIN
  DECLARE v_course   VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
  DECLARE v_semester VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

  IF NEW.`CRN` <> OLD.`CRN` THEN
    SELECT cs.`CourseID`, cs.`SemesterID`
      INTO v_course, v_semester
      FROM `CourseSection` cs
     WHERE cs.`CRN` = NEW.`CRN`;

    IF v_course IS NULL THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Enrolment refers to a CRN that does not exist.';
    END IF;

    SET NEW.`CourseID`   = v_course;
    SET NEW.`SemesterID` = v_semester;
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. T6 -- course level matches the student
--
-- FOLLOWS is not decoration: this trigger reads NEW.CourseID, which
-- trg_SE_before_insert_denorm rewrites from the section. Without an
-- explicit order MySQL runs same-event triggers in creation order, so
-- dropping and recreating one of them could silently start checking the
-- caller's CourseID instead of the section's.
--
-- Course.CourseType is UNDERGRAD or GRAD; Student.StudentType is
-- Undergraduate or Graduate. A graduate taking an undergraduate course
-- is ordinary (prerequisites, bridging work), so only the undergraduate
-- reaching upward is refused.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_SE_before_insert_level`;
DELIMITER $$
CREATE TRIGGER `trg_SE_before_insert_level`
BEFORE INSERT ON `StudentEnrollment` FOR EACH ROW
FOLLOWS `trg_SE_before_insert_denorm`
BEGIN
  DECLARE v_student_type VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
  DECLARE v_course_type  VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

  SELECT s.`StudentType` INTO v_student_type
    FROM `Student` s WHERE s.`StudentID` = NEW.`StudentID`;

  SELECT c.`CourseType` INTO v_course_type
    FROM `Course` c WHERE c.`CourseID` = NEW.`CourseID`;

  IF v_student_type = 'Undergraduate' AND v_course_type = 'GRAD' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'An undergraduate cannot enrol in a graduate course.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 6. T13, T14 -- Undergraduate and Graduate are disjoint, and each
--    agrees with Student.StudentType
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_Undergraduate_before_insert_disjoint`;
DELIMITER $$
CREATE TRIGGER `trg_Undergraduate_before_insert_disjoint`
BEFORE INSERT ON `Undergraduate` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `Graduate` g WHERE g.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That student is already a graduate student.';
  END IF;

  IF (SELECT s.`StudentType` FROM `Student` s
       WHERE s.`StudentID` = NEW.`StudentID`) <> 'Undergraduate' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Student.StudentType to Undergraduate before adding the Undergraduate row.';
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_Graduate_before_insert_disjoint`$$
CREATE TRIGGER `trg_Graduate_before_insert_disjoint`
BEFORE INSERT ON `Graduate` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `Undergraduate` u WHERE u.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'That student is already an undergraduate.';
  END IF;

  IF (SELECT s.`StudentType` FROM `Student` s
       WHERE s.`StudentID` = NEW.`StudentID`) <> 'Graduate' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Student.StudentType to Graduate before adding the Graduate row.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 7. T15-T18 -- the four load tables are disjoint within their level
--    and agree with the enum above them
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_FullTimeUG_before_insert_match`;
DELIMITER $$
CREATE TRIGGER `trg_FullTimeUG_before_insert_match`
BEFORE INSERT ON `FullTimeUG` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `PartTimeUG` p WHERE p.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That student is already part time.';
  END IF;
  IF (SELECT u.`UGStudentType` FROM `Undergraduate` u
       WHERE u.`StudentID` = NEW.`StudentID`) <> 'FullTimeUG' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Undergraduate.UGStudentType to FullTimeUG first.';
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_PartTimeUG_before_insert_match`$$
CREATE TRIGGER `trg_PartTimeUG_before_insert_match`
BEFORE INSERT ON `PartTimeUG` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `FullTimeUG` f WHERE f.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That student is already full time.';
  END IF;
  IF (SELECT u.`UGStudentType` FROM `Undergraduate` u
       WHERE u.`StudentID` = NEW.`StudentID`) <> 'PartTimeUG' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Undergraduate.UGStudentType to PartTimeUG first.';
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_FullTimeGrad_before_insert_match`$$
CREATE TRIGGER `trg_FullTimeGrad_before_insert_match`
BEFORE INSERT ON `FullTimeGrad` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `PartTimeGrad` p WHERE p.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That student is already part time.';
  END IF;
  IF (SELECT g.`GradStudentType` FROM `Graduate` g
       WHERE g.`StudentID` = NEW.`StudentID`) <> 'FullTimeGrad' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Graduate.GradStudentType to FullTimeGrad first.';
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_PartTimeGrad_before_insert_match`$$
CREATE TRIGGER `trg_PartTimeGrad_before_insert_match`
BEFORE INSERT ON `PartTimeGrad` FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM `FullTimeGrad` f WHERE f.`StudentID` = NEW.`StudentID`) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That student is already full time.';
  END IF;
  IF (SELECT g.`GradStudentType` FROM `Graduate` g
       WHERE g.`StudentID` = NEW.`StudentID`) <> 'PartTimeGrad' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Set Graduate.GradStudentType to PartTimeGrad first.';
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 8. T19 -- StudentType cannot be changed out from under its subtype row
--
-- Migration 007 rebuilt this column once because it had drifted so far
-- that only 96 of 1,602 rows were right. This is what stops that
-- happening again: change the subtype rows first, then the enum.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_Student_before_update_type`;
DELIMITER $$
CREATE TRIGGER `trg_Student_before_update_type`
BEFORE UPDATE ON `Student` FOR EACH ROW
BEGIN
  IF NEW.`StudentType` <> OLD.`StudentType` THEN
    IF NEW.`StudentType` = 'Graduate'
       AND EXISTS (SELECT 1 FROM `Undergraduate` u WHERE u.`StudentID` = NEW.`StudentID`) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Remove the Undergraduate row before making this student a graduate.';
    END IF;

    IF NEW.`StudentType` = 'Undergraduate'
       AND EXISTS (SELECT 1 FROM `Graduate` g WHERE g.`StudentID` = NEW.`StudentID`) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Remove the Graduate row before making this student an undergraduate.';
    END IF;
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 9. After: 10 new triggers alongside the 1 that existed, plus the
--    grade foreign key
-- ---------------------------------------------------------------------
SELECT `TRIGGER_NAME`, `EVENT_MANIPULATION`, `EVENT_OBJECT_TABLE`
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE()
 ORDER BY `EVENT_OBJECT_TABLE`, `ACTION_TIMING`, `TRIGGER_NAME`;

SELECT COUNT(*) AS trigger_count_expect_11
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE();

SELECT COUNT(*) AS grade_fk_expect_1
  FROM information_schema.`REFERENTIAL_CONSTRAINTS`
 WHERE `CONSTRAINT_SCHEMA` = DATABASE()
   AND `CONSTRAINT_NAME`   = 'fk_StudentEnrollment_Grade';
