-- =====================================================================
-- 011_studentmajor_authoritative.sql
-- Makes StudentMajor the record of a student's major and demotes
-- Student.MajorID to a cache the database maintains.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 011_studentmajor_authoritative.sql
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- A student's major is recorded twice, and the two records disagree for
-- most of the student body:
--
--   1,602  students carry a Student.MajorID
--   1,290  students have at least one StudentMajor declaration
--     138  of those agree with Student.MajorID
--   1,152  have a Student.MajorID that is not among their declarations
--     312  have a Student.MajorID and no declaration at all
--
-- StudentMajor is the better record. It carries DateOfDeclaration, it
-- supports the 165 students who hold a double major, and it is what
-- UpdateDegreeAudit already reads -- ordering by DateOfDeclaration and
-- taking the first. Student.MajorID cannot express any of that.
--
-- The minor side is in far better shape -- no student holds two minors
-- and no cached MinorID contradicts a declaration -- but 140 of the 697
-- students who have declared a minor carry no MinorID at all, so the
-- cache is empty rather than wrong. Section 2 fills those in.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ---------------------------------------------------------------------
-- The 312 students with a MajorID and no declaration are left exactly
-- as they are. Their MajorID spreads realistically across all ten
-- majors -- 44 Biology, 39 MIS, 38 Psychology and so on -- so it is real
-- information, not a default that crept in. Writing declarations for
-- them would mean inventing 312 DateOfDeclaration values, 216 of them
-- for students with no enrolment history to date from; nulling their
-- MajorID would throw the information away. Both are worse than leaving
-- the question open, so it stays open, and section 5 lists them.
--
-- Consequence: those 312 keep a cached major with nothing behind it.
-- The guard in section 4 only fires when MajorID changes, so they are
-- grandfathered rather than broken.
-- =====================================================================

SET NAMES utf8mb4;


-- ---------------------------------------------------------------------
-- 1. Before
-- ---------------------------------------------------------------------
SELECT 'MajorID agrees with a declaration' AS state, COUNT(*) AS students
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND EXISTS (SELECT 1 FROM `StudentMajor` sm
                WHERE sm.`StudentID` = s.`StudentID` AND sm.`MajorID` = s.`MajorID`)
UNION ALL
SELECT 'MajorID contradicts the declarations', COUNT(*)
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm
                    WHERE sm.`StudentID` = s.`StudentID` AND sm.`MajorID` = s.`MajorID`)
UNION ALL
SELECT 'MajorID with no declaration (left alone)', COUNT(*)
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
UNION ALL
SELECT 'declared, but MajorID is NULL', COUNT(*)
  FROM `Student` s
 WHERE s.`MajorID` IS NULL
   AND EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`);


-- ---------------------------------------------------------------------
-- 2. Repair the cache from the record
--
-- Earliest declaration wins, ties broken by MajorID -- the same order
-- UpdateDegreeAudit uses to pick the major it audits against, so the
-- cache and the audit now name the same major.
--
-- Only students who have a declaration are touched. The 312 without one
-- are excluded by the JOIN.
-- ---------------------------------------------------------------------
UPDATE `Student` s
  JOIN (
        SELECT sm.`StudentID`,
               SUBSTRING_INDEX(
                 GROUP_CONCAT(sm.`MajorID`
                   ORDER BY sm.`DateOfDeclaration`, sm.`MajorID` SEPARATOR ','),
                 ',', 1) AS primary_major
          FROM `StudentMajor` sm
         GROUP BY sm.`StudentID`
       ) d ON d.`StudentID` = s.`StudentID`
   SET s.`MajorID` = CAST(d.primary_major AS UNSIGNED)
 WHERE s.`MajorID` IS NULL
    OR s.`MajorID` <> CAST(d.primary_major AS UNSIGNED);

SELECT ROW_COUNT() AS major_cache_repaired;


-- The same for minors. No student holds two minors and no cached minor
-- contradicts a declaration, so this is smaller than it looks: 697
-- students have declared a minor and only 557 carry it on Student, so
-- 140 caches are simply empty. Same rule as majors, so both columns
-- mean the same thing.
UPDATE `Student` s
  JOIN (
        SELECT sm.`StudentID`,
               SUBSTRING_INDEX(
                 GROUP_CONCAT(sm.`MinorID`
                   ORDER BY sm.`DateOfDeclaration`, sm.`MinorID` SEPARATOR ','),
                 ',', 1) AS primary_minor
          FROM `StudentMinor` sm
         GROUP BY sm.`StudentID`
       ) d ON d.`StudentID` = s.`StudentID`
   SET s.`MinorID` = CAST(d.primary_minor AS UNSIGNED)
 WHERE s.`MinorID` IS NULL
    OR s.`MinorID` <> CAST(d.primary_minor AS UNSIGNED);

SELECT ROW_COUNT() AS minor_cache_repaired;


-- ---------------------------------------------------------------------
-- 3. T20 -- the cache follows the record from here on
--
-- Three triggers per table, because the primary major can change when a
-- declaration is added, edited or withdrawn. Each recomputes from
-- scratch rather than reasoning about the delta, which is cheap at this
-- size and cannot drift.
--
-- Deleting a student's last declaration sets MajorID back to NULL: no
-- declaration means no major, which is the whole point of making
-- StudentMajor authoritative.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `nu_resync_major`;
DELIMITER $$
CREATE PROCEDURE `nu_resync_major`(IN p_student INT UNSIGNED)
BEGIN
  UPDATE `Student` s
     SET s.`MajorID` = (
           SELECT sm.`MajorID` FROM `StudentMajor` sm
            WHERE sm.`StudentID` = p_student
            ORDER BY sm.`DateOfDeclaration`, sm.`MajorID`
            LIMIT 1)
   WHERE s.`StudentID` = p_student;
END$$

DROP PROCEDURE IF EXISTS `nu_resync_minor`$$
CREATE PROCEDURE `nu_resync_minor`(IN p_student INT UNSIGNED)
BEGIN
  UPDATE `Student` s
     SET s.`MinorID` = (
           SELECT sm.`MinorID` FROM `StudentMinor` sm
            WHERE sm.`StudentID` = p_student
            ORDER BY sm.`DateOfDeclaration`, sm.`MinorID`
            LIMIT 1)
   WHERE s.`StudentID` = p_student;
END$$

DROP TRIGGER IF EXISTS `trg_StudentMajor_after_insert_sync`$$
CREATE TRIGGER `trg_StudentMajor_after_insert_sync`
AFTER INSERT ON `StudentMajor` FOR EACH ROW
BEGIN CALL `nu_resync_major`(NEW.`StudentID`); END$$

DROP TRIGGER IF EXISTS `trg_StudentMajor_after_update_sync`$$
CREATE TRIGGER `trg_StudentMajor_after_update_sync`
AFTER UPDATE ON `StudentMajor` FOR EACH ROW
BEGIN
  CALL `nu_resync_major`(NEW.`StudentID`);
  IF OLD.`StudentID` <> NEW.`StudentID` THEN
    CALL `nu_resync_major`(OLD.`StudentID`);
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_StudentMajor_after_delete_sync`$$
CREATE TRIGGER `trg_StudentMajor_after_delete_sync`
AFTER DELETE ON `StudentMajor` FOR EACH ROW
BEGIN CALL `nu_resync_major`(OLD.`StudentID`); END$$

DROP TRIGGER IF EXISTS `trg_StudentMinor_after_insert_sync`$$
CREATE TRIGGER `trg_StudentMinor_after_insert_sync`
AFTER INSERT ON `StudentMinor` FOR EACH ROW
BEGIN CALL `nu_resync_minor`(NEW.`StudentID`); END$$

DROP TRIGGER IF EXISTS `trg_StudentMinor_after_update_sync`$$
CREATE TRIGGER `trg_StudentMinor_after_update_sync`
AFTER UPDATE ON `StudentMinor` FOR EACH ROW
BEGIN
  CALL `nu_resync_minor`(NEW.`StudentID`);
  IF OLD.`StudentID` <> NEW.`StudentID` THEN
    CALL `nu_resync_minor`(OLD.`StudentID`);
  END IF;
END$$

DROP TRIGGER IF EXISTS `trg_StudentMinor_after_delete_sync`$$
CREATE TRIGGER `trg_StudentMinor_after_delete_sync`
AFTER DELETE ON `StudentMinor` FOR EACH ROW
BEGIN CALL `nu_resync_minor`(OLD.`StudentID`); END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 4. The cache cannot be set to something that was never declared
--
-- Without this, "StudentMajor is authoritative" is a convention rather
-- than a rule, and the next screen that writes Student.MajorID directly
-- puts the two back out of step -- which is how they got here.
-- UpdateUsers.php was doing exactly that and is changed alongside this
-- migration to declare first.
--
-- Fires only when the column actually changes, so the 312 rows in
-- section 5 are grandfathered rather than frozen.
--
-- Honours @nu_override for a registrar correcting a record by hand:
--     SET @nu_override = 1;
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_Student_before_update_majorcache`;
DELIMITER $$
CREATE TRIGGER `trg_Student_before_update_majorcache`
BEFORE UPDATE ON `Student` FOR EACH ROW
FOLLOWS `trg_Student_before_update_type`
BEGIN
  IF COALESCE(@nu_override, 0) <> 1 THEN

    IF NEW.`MajorID` IS NOT NULL
       AND NOT (OLD.`MajorID` <=> NEW.`MajorID`)
       AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm
                        WHERE sm.`StudentID` = NEW.`StudentID`
                          AND sm.`MajorID`   = NEW.`MajorID`) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Student.MajorID follows StudentMajor. Insert the declaration first, or SET @nu_override = 1.';
    END IF;

    IF NEW.`MinorID` IS NOT NULL
       AND NOT (OLD.`MinorID` <=> NEW.`MinorID`)
       AND NOT EXISTS (SELECT 1 FROM `StudentMinor` sm
                        WHERE sm.`StudentID` = NEW.`StudentID`
                          AND sm.`MinorID`   = NEW.`MinorID`) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Student.MinorID follows StudentMinor. Insert the declaration first, or SET @nu_override = 1.';
    END IF;

  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. After
-- ---------------------------------------------------------------------
SELECT 'cache disagrees with the record' AS check_name, COUNT(*) AS expect_0
  FROM `Student` s
 WHERE EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
   AND NOT (s.`MajorID` <=> (SELECT sm.`MajorID` FROM `StudentMajor` sm
                              WHERE sm.`StudentID` = s.`StudentID`
                              ORDER BY sm.`DateOfDeclaration`, sm.`MajorID` LIMIT 1))
UNION ALL
SELECT 'minor cache disagrees with the record', COUNT(*)
  FROM `Student` s
 WHERE EXISTS (SELECT 1 FROM `StudentMinor` sm WHERE sm.`StudentID` = s.`StudentID`)
   AND NOT (s.`MinorID` <=> (SELECT sm.`MinorID` FROM `StudentMinor` sm
                              WHERE sm.`StudentID` = s.`StudentID`
                              ORDER BY sm.`DateOfDeclaration`, sm.`MinorID` LIMIT 1));

-- The open question, listed so it is not forgotten. Each of these has a
-- major on file and no declaration behind it; decide whether to write
-- the declaration or clear the major.
SELECT COUNT(*) AS students_with_major_but_no_declaration
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`);

SELECT s.`MajorID`, m.`MajorName`, COUNT(*) AS students
  FROM `Student` s
  LEFT JOIN `Major` m ON m.`MajorID` = s.`MajorID`
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
 GROUP BY s.`MajorID`, m.`MajorName`
 ORDER BY students DESC;
