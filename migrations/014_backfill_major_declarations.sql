-- =====================================================================
-- 014_backfill_major_declarations.sql
-- Writes a StudentMajor row for the 312 students migration 011 left
-- alone: a Student.MajorID with no declaration behind it.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 014_backfill_major_declarations.sql
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- 011 made StudentMajor the record and Student.MajorID a cache the
-- database maintains from it -- everywhere except these 312, where the
-- cache holds a value with nothing behind it. They split into two
-- groups on the one thing that could tell them apart: whether the
-- student has ever enrolled in anything.
--
--   96  have enrolment history. The date they first enrolled in
--       anything is real evidence -- they were already a student,
--       already working toward something, by then. DateOfDeclaration
--       is backfilled from MIN(StudentEnrollment.EnrollmentDate).
--
--  216  have never enrolled in a single course, despite being ACTIVE.
--       There is no date anywhere in the schema to anchor a declaration
--       to -- Student and Users carry no admission or creation date.
--       Inventing one would be indistinguishable from the 1,152 that
--       011 already refused to guess at.
--
-- For the 216, DateOfDeclaration is set to CURDATE() -- the date this
-- migration runs, not a claimed historical fact. That is a legitimate,
-- ordinary move for a required NOT NULL column with no source date: it
-- records "declared, effective as of this backfill," and is honest
-- about being an administrative date rather than a memory of the past.
-- It only affects tie-breaking in nu_resync_major's ORDER BY, and none
-- of the 216 have a second declaration to break a tie against.
--
-- Both groups insert into StudentMajor from a staging temp table, not
-- straight from Student. A direct "INSERT ... SELECT ... FROM Student"
-- fires trg_StudentMajor_after_insert_sync per row, which calls
-- nu_resync_major, which UPDATEs Student -- and MySQL refuses to let a
-- trigger update a table its invoking statement is still reading
-- (ERROR 1442). Staging breaks that chain. Nothing here writes to
-- Student.MajorID directly either way; the sync trigger recomputes it
-- from the row just inserted, the same path any other declaration
-- takes. Since the cache already holds this exact MajorID, the resync
-- is a no-op in effect -- exercised anyway rather than special-cased.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 1. Before
-- ---------------------------------------------------------------------
SELECT 'Student.MajorID with no StudentMajor row' AS check_name, COUNT(*) AS n
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
UNION ALL
SELECT '  of those, with enrolment history', COUNT(*)
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
   AND EXISTS (SELECT 1 FROM `StudentEnrollment` se WHERE se.`StudentID` = s.`StudentID`)
UNION ALL
SELECT '  of those, with none', COUNT(*)
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`)
   AND NOT EXISTS (SELECT 1 FROM `StudentEnrollment` se WHERE se.`StudentID` = s.`StudentID`);


-- ---------------------------------------------------------------------
-- 2. Stage the backfill
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS `_backfill_major_declarations`;
CREATE TEMPORARY TABLE `_backfill_major_declarations` AS
SELECT s.`StudentID`, s.`MajorID`,
       COALESCE(
         (SELECT MIN(se.`EnrollmentDate`) FROM `StudentEnrollment` se WHERE se.`StudentID` = s.`StudentID`),
         CURDATE()
       ) AS `DateOfDeclaration`
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`);

SELECT COUNT(*) AS staged_expect_312 FROM `_backfill_major_declarations`;


-- ---------------------------------------------------------------------
-- 3. Write it
-- ---------------------------------------------------------------------
INSERT INTO `StudentMajor` (`StudentID`, `MajorID`, `DateOfDeclaration`)
SELECT `StudentID`, `MajorID`, `DateOfDeclaration` FROM `_backfill_major_declarations`;

DROP TEMPORARY TABLE `_backfill_major_declarations`;


-- ---------------------------------------------------------------------
-- 4. After
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS orphans_remaining_expect_0
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm WHERE sm.`StudentID` = s.`StudentID`);

SELECT COUNT(*) AS cache_disagreements_expect_0
  FROM `Student` s
 WHERE s.`MajorID` IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM `StudentMajor` sm
                    WHERE sm.`StudentID` = s.`StudentID` AND sm.`MajorID` = s.`MajorID`);
