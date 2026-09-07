-- =====================================================================
-- 018_fix_major_name.sql
-- MajorID 1 is named "Mathematics Minor" in the Major table.
-- =====================================================================
--
--   mysql -h 127.0.0.1 -u root University < 018_fix_major_name.sql
--
-- ---------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------
-- Every other row in Major is named after its department alone --
-- Computer Science, Biology, Chemistry, and so on. MajorID 1 is the one
-- exception: "Mathematics Minor", a copy-paste from the row that
-- belongs in Minor -- MinorID 1 already carries that exact name,
-- correctly, on its own table. Major's row is a real major in every
-- other respect (48 credits needed, 40 requirement rows), just
-- mislabeled. No other Major is named "Mathematics", so this collides
-- with nothing.
-- ---------------------------------------------------------------------
UPDATE `Major` SET `MajorName` = 'Mathematics' WHERE `MajorID` = 1 AND `MajorName` = 'Mathematics Minor';

SELECT `MajorID`, `MajorName`, `CreditsNeeded` FROM `Major` WHERE `MajorID` = 1;
