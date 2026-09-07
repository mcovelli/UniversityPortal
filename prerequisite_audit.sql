WITH prerequisites AS (
	SELECT c.CourseID, p.PrerequisiteCourseID, p.MinGradeRequired
	FROM Course c
	INNER JOIN CoursePrerequisite p ON c.CourseID = p.CourseID
	GROUP BY c.CourseID, p.PrerequisiteCourseID
)

SELECT se.StudentID, se.CourseID, se.Grade, se.Status
FROM StudentEnrollment se
JOIN prerequisites p ON p.CourseID = se.CourseID
WHERE NOT EXISTS (
	SELECT * 
    FROM StudentEnrollment hist 
    JOIN GradingScale gs ON hist.Grade = gs.GradeLetter
    JOIN GradingScale pgs ON p.MinGradeRequired = pgs.GradeLetter
    WHERE hist.StudentID = se.StudentID 
		AND hist.Status = "COMPLETED" 
        AND hist.CourseID = p.PrerequisiteCourseID 
        AND gs.GradeValue >= pgs.GradeValue	
) AND se.Status IN ("PLANNED", "WAITLIST", "ENROLLED")
GROUP BY se.StudentID, se.CourseID, se.Grade, se.Status