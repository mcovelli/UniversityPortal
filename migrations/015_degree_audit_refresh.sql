-- =====================================================================
-- 015_degree_audit_refresh.sql
-- Group D from the trigger review: derived data that only updated when
-- someone remembered to ask for it.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 015_degree_audit_refresh.sql
--
-- Ships with an edit to CreateUsers.php -- section 3 below.
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- DegreeAudit only refreshes when degree_audit.php loads and calls
-- UpdateDegreeAudit itself. A grade posted through grade.php or
-- grade_update.php doesn't touch it -- the stored audit, and anything
-- that reads it without also viewing that one page (an advisor, a
-- transcript, a report), sees whatever was true the last time the
-- student happened to look.
--
-- The review also flagged a second column carrying the same fact:
-- CreditsEarned on FullTimeUG / PartTimeUG / FullTimeGrad / PartTimeGrad.
-- It turns out nothing in the application ever reads it -- CreateUsers.php
-- is the only file that mentions it anywhere, and only to set it to 0 at
-- creation. Nothing has updated it since: 973 of 982 FullTimeUG rows
-- disagree with their actual completed credits. A trigger could keep a
-- second copy in sync, but that's two places computing the same number
-- with two chances to disagree again -- DegreeAudit.Credits_Completed
-- already is that number, correctly, and something a student can look
-- at. The column is dropped rather than repaired.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 1. Before
-- ---------------------------------------------------------------------
SELECT 'FullTimeUG rows where CreditsEarned disagrees with completed credits' AS check_name, COUNT(*) AS n
  FROM `FullTimeUG` f
 WHERE f.`CreditsEarned` <> (
   SELECT COALESCE(SUM(c.`Credits`), 0) FROM `StudentEnrollment` se JOIN `Course` c ON c.`CourseID` = se.`CourseID`
    WHERE se.`StudentID` = f.`StudentID` AND se.`Status` = 'COMPLETED' AND se.`Grade` IS NOT NULL AND se.`Grade` <> 'F');


-- ---------------------------------------------------------------------
-- 2. T21 -- refresh the audit when a grade lands
-- ---------------------------------------------------------------------
-- Fires only on what could actually change UpdateDegreeAudit's numbers:
-- a grade set or changed, or a row newly becoming COMPLETED. A plain
-- drop (Status changes, Grade stays NULL) does neither and is skipped.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_SE_after_update_audit`;
DELIMITER $$
CREATE TRIGGER `trg_SE_after_update_audit`
AFTER UPDATE ON `StudentEnrollment` FOR EACH ROW
BEGIN
  IF NOT (OLD.`Grade` <=> NEW.`Grade`)
     OR (NEW.`Status` = 'COMPLETED' AND OLD.`Status` <> 'COMPLETED') THEN
    CALL `UpdateDegreeAudit`(NEW.`StudentID`);
  END IF;
END$$
DELIMITER ;


-- ---------------------------------------------------------------------
-- 3. Drop the column nothing reads
-- ---------------------------------------------------------------------
ALTER TABLE `FullTimeUG`   DROP COLUMN `CreditsEarned`;
ALTER TABLE `PartTimeUG`   DROP COLUMN `CreditsEarned`;
ALTER TABLE `FullTimeGrad` DROP COLUMN `CreditsEarned`;
ALTER TABLE `PartTimeGrad` DROP COLUMN `CreditsEarned`;


-- ---------------------------------------------------------------------
-- 4. After
-- ---------------------------------------------------------------------
SELECT `TRIGGER_NAME`, `EVENT_MANIPULATION`
  FROM information_schema.`TRIGGERS`
 WHERE `TRIGGER_SCHEMA` = DATABASE() AND `EVENT_OBJECT_TABLE` = 'StudentEnrollment'
 ORDER BY `EVENT_MANIPULATION`, `ACTION_ORDER`;

SELECT COUNT(*) AS trigger_count_expect_34
  FROM information_schema.`TRIGGERS` WHERE `TRIGGER_SCHEMA` = DATABASE();
