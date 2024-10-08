
  
EXEC [Doc] 'Add','Schema.Procedure','dbo.Validate Leave Request','Implement rule to raise error when exceed with available balance.','Yes','11/07/2024 23:33'; 
GO


/****** Object:  StoredProcedure [dbo].[Validate Leave Request]    Script Date: 11/07/2024 23:33:46 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROC [dbo].[Validate Leave Request]
@Employee int,
@AbsenceTransaction nvarchar(50),
@StartDate datetime,
@EndDate datetime,
@HalfDays nvarchar(5),
@Comments nvarchar(50),
@Status nvarchar(50),
@IsSalaryAdvance nvarchar(3),
@ContactDuringLeave nvarchar(255),
@AlternativeManager int,
@IsTicket nvarchar(5)
AS
	------- GET EMPLOYEE DETAILS/VARIABLES -------------------------------------------
	DECLARE @entity int,
			@EngagementDate datetime,
			@ServicePeriod float,
			@Nationality nvarchar(100),
			@Gender nvarchar(255),
			@Religion nvarchar(25),
			@Grade nvarchar(100),
			@MaritalStatus nvarchar(255),
			@probationDate datetime

	SELECT  @probationDate = [Probation Date],
			@engagementDate = [Engagement Date]
	FROM [PER HRA Personal Employment]
	WHERE Employee = @Employee

	SELECT @Grade = [Grade]
	FROM CO_SRC_Search_VIEW
	WHERE Employee = @Employee
	
	SELECT @ServicePeriod = DATEDIFF(month, @engagementDate,GETDATE())/12.0

	SELECT  @MaritalStatus  = [Marital Status],
			@Religion		= [Religion],
			@Nationality	= [Nationality],
			@Gender			= [Gender],
			@Entity			= [Entity]
	FROM [PER HRA PERSONAL]
	WHERE EMPLOYEE = @Employee

	-- GENERAL CHECKS -----------------------------------
	
	-- Leave before engagement date
	IF(@StartDate < @EngagementDate)
	BEGIN
			RAISERROR ('Employee can''t apply for leave before their joining date. Please verify your data and try again.',16,1)
			RETURN
	END

	-- Salary Advance
	IF(@AbsenceTransaction <> 'Annual Leave' and @IsSalaryAdvance = 'Yes')
	BEGIN
			RAISERROR ('Leave Salary advance option is only applicable for annual leave only.',16,1)
			RETURN
	END

	-- LEAVE BALANCE AND LEAVE SCHEME CHECKS ------------
	DECLARE @minimum int,
			@maximum int,
			@Balance numeric(18,2),
			@lvesch nvarchar(50)

	SELECT  @lvesch = [Leave Scheme]
	FROM [CO_SRC_Search_VIEW]
	WHERE EMPLOYEE = @Employee

	SELECT
	@Minimum = A.Minimum,
	@Maximum = A.Maximum
	FROM [CO LVE Leave Schemes] A
	INNER JOIN [CO LVE Leave Type] B
	ON A.Element = B.[Leave Element]
	INNER JOIN [CO LVE Leave Schemes Master] C
	ON A.[Leave Scheme Master] = C.[Leave Scheme Master] AND B.Company = C.Entity
	WHERE
	A.[Leave Scheme] = @lvesch
	AND B.[Leave Element] = @AbsenceTransaction
	AND B.Company = @Entity

	SELECT TOP 1
	@Balance =
	CASE
		WHEN @AbsenceTransaction = 'Annual Leave' THEN [Annual Leave (Bal Cfwd)]
		WHEN @AbsenceTransaction = 'Sick Leave' THEN [Sick Leave (Bal Cfwd)]
	END
	FROM [PER REM Payroll Calc] A
	WHERE [Employee] = @Employee AND [Calc Status] = 'RELEASED'
	ORDER BY A.[Interval] DESC	

	IF @Balance < @Minimum
	BEGIN
		RAISERROR('You require more balance for this Absence Transaction',16,1)
		RETURN
	END
	---------------- LEAVE RULE CHECKS ------------------------------------------------------
	
	DECLARE @RuleCode nvarchar(100),
	@MinServicePeriodRule float,
	@MaxServicePeriodRule float,
	@ExpatRule nvarchar(100),
	@GenderRule nvarchar(50),
	@ReligionRule nvarchar(50),
	@MaritalStatusRule nvarchar(100),
	@GradeRule nvarchar(50),
	@ProbationRule nvarchar(50),
	@MinDateDiffRule int,
	@MaxDateDiffRule int,
	@UseCalendarDetail nvarchar(50),
	@MaxDays int,
	@MaxRequests int,
	@NumRequestUnits float,
	@RequestUnits nvarchar(100)

	-- NO RULES = OK
	IF NOT EXISTS(SELECT * FROM [CO LVE Absence Transaction Rules] WHERE [Absence Transaction] = @AbsenceTransaction AND Entity = @entity)
		RETURN
	
	DECLARE @ErrorLevel int = 0,
			@ErrorMaxDays int = 0,
			@ErrorDateDiff int = 0

	DECLARE leave_rule_cursor CURSOR FOR
	SELECT [Rule Code]
		,[Minimum Service Period]
		,[Maximum Service Period]
		,[Expat]
		,[Gender]
		,[Religion]
		,[Marital Status]
		,[Grade]
		,[Probation]
		,[Minimum Days Before Request]
		,[Maximum Days Before Request]
		,[Use Calendar Detail]
		,[Maximum Number of Days]
		,[Maximum Number of Requests]
		,[Number of Units]
		,[Unit]
	FROM [CO LVE Absence Transaction Rules]
	WHERE [Absence Transaction] = @AbsenceTransaction AND Entity = @entity

	OPEN leave_rule_cursor
	FETCH NEXT FROM leave_rule_cursor
	INTO @RuleCode,
		@MinServicePeriodRule,
		@MaxServicePeriodRule,
		@ExpatRule,
		@GenderRule,
		@ReligionRule,
		@MaritalStatusRule,
		@GradeRule,
		@ProbationRule,
		@MinDateDiffRule,
		@MaxDateDiffRule,
		@UseCalendarDetail,
		@MaxDays,
		@MaxRequests,
		@NumRequestUnits,
		@RequestUnits

	WHILE @@FETCH_STATUS = 0
	BEGIN
		DECLARE @NumberofDays int
		DECLARE @RequestCount int
		DECLARE @IsValid bit = 1
		-- Match criteria

		-- Minimum Service Period
		If @IsValid = 1 AND @MinServicePeriodRule IS NOT NULL AND @MinServicePeriodRule > @ServicePeriod
			SET @IsValid = 0

		-- Maximum Service Period
		If @IsValid = 1 AND @MaxServicePeriodRule IS NOT NULL AND @MaxServicePeriodRule <= @ServicePeriod
			SET @IsValid = 0 

		-- If at this point @IsValid = 0 Then the rule does not match the service period requirements for this request
		-- No point in looking at other criterias and time for the next rule
		IF @IsValid = 0
			SET @ErrorLevel = CASE WHEN @ErrorLevel < 1 THEN 1 ELSE @ErrorLevel END

		IF @IsValid = 1 AND 
		((@ExpatRule IS NOT NULL AND @ExpatRule <> 'ALL NATIONALITIES' AND @ExpatRule <> @Nationality)
		OR (@GenderRule IS NOT NULL AND @GenderRule <> @Gender)
		OR (@ReligionRule IS NOT NULL AND @ReligionRule <> @Religion)
		OR (@MaritalStatusRule IS NOT NULL AND @MaritalStatusRule <> @MaritalStatus)
		OR (@GradeRule IS NOT NULL AND @GradeRule <> @Grade)
		OR (@StartDate <= @probationdate AND @ProbationRule = 'No'))
		BEGIN
			SET @IsValid = 0
			SET @ErrorLevel = CASE WHEN @ErrorLevel < 2 THEN 2 ELSE @ErrorLevel END
		END


			-- Days before request
		DECLARE @DateDiff int
		SET @DateDiff = DATEDIFF(day,GETDATE(), @StartDate)

		IF @IsValid = 1 AND @MinDateDiffRule IS NOT NULL AND @DateDiff < @MinDateDiffRule
		BEGIN
			SET @IsValid = 0
			SET @ErrorLevel = CASE WHEN @ErrorLevel < 3 THEN 3 ELSE @ErrorLevel END
			SET @ErrorDateDiff = @MinDateDiffRule
		END

		IF @IsValid = 1 AND @MaxDateDiffRule IS NOT NULL AND @DateDiff > @MaxDateDiffRule
		BEGIN
			SET @IsValid = 0
			SET @ErrorLevel = CASE WHEN @ErrorLevel < 4 THEN 4 ELSE @ErrorLevel END
			SET @ErrorDateDiff = @MaxDateDiffRule
		END

			-- Maximum # of days
		SELECT @NumberofDays = COUNT(Detail)
		FROM [GP SRC Calendar Detail] (NOLOCK)
		WHERE [Date] >= @StartDate
		AND [Date] <= @EndDate
		AND [Day Type] NOT IN ('Holiday', 'Weekend')
		AND [Calendar] = @UseCalendarDetail

		IF @IsValid = 1 AND ISNULL(@NumberofDays, DATEDIFF(day, @StartDate, @EndDate)) > @MaxDays
		BEGIN
			SET @IsValid = 0
			SET @ErrorLevel = CASE WHEN @ErrorLevel < 5 THEN 5 ELSE @ErrorLevel END
			SET @ErrorMaxDays = @MaxDays
		END

			-- Request Rate
		IF @IsValid = 1 AND @RequestUnits IS NOT NULL
		BEGIN

			DECLARE @LastLeaveReturnDate datetime

			SELECT TOP 1 @LastLeaveReturnDate = [End Date]
			FROM [PER LVE Absence Schedule]
			WHERE [Absence Code] = @AbsenceTransaction
			AND Employee = @Employee
			AND [End Date] < @StartDate
			ORDER BY [End Date] DESC
			
			IF @RequestUnits = 'SERVICE PERIOD' AND @LastLeaveReturnDate IS NOT NULL
			BEGIN
				SET @IsValid = 0
				SET @ErrorLevel = CASE WHEN @ErrorLevel < 6 THEN 6 ELSE @ErrorLevel END 
			END

			DECLARE @requestRateStart datetime
			SET @requestRateStart = CASE WHEN @RequestUnits = 'YEAR' THEN DATEADD(year, -1*@NumRequestUnits, @StartDate)
										 WHEN @RequestUnits = 'MONTH' THEN DATEADD(month, -1*@NumRequestUnits, @StartDate)
										 WHEN @RequestUnits = 'WEEK' THEN DATEADD(week, -1*@NumRequestUnits, @StartDate) END
			--PRINT @RequestUnits
			--PRINT CAST(@requestRateStart as nvarchar(100))
			
			IF @IsValid = 1 AND @requestRateStart IS NOT NULL
			BEGIN

				SELECT @RequestCount = COUNT(*)
				FROM  [PER LVE Absence Schedule]
				WHERE [Absence Code] = @AbsenceTransaction
				AND Employee = @Employee
				AND [Start Date] <= @StartDate
				AND [End Date] >= @requestRateStart

				--PRINT CAST(@RequestCount as nvarchar(100))
				

				IF @RequestCount >= @MaxRequests
				BEGIN
					SET @IsValid = 0
					SET @ErrorLevel = CASE WHEN @ErrorLevel < 7 THEN 7 ELSE @ErrorLevel END 
				END

			END
		END

		IF EXISTS(SELECT 1 FROM  [PER LVE Absence Schedule]
		WHERE [Absence Code] = @AbsenceTransaction
		AND Employee = @Employee
		AND [Start Date] <= @StartDate
		AND [End Date] >= @EndDate
		) AND @AbsenceTransaction = 'Annual Leave'
			BEGIN
				SELECT @RequestCount = COUNT(*)
				FROM  [PER LVE Absence Schedule]
				WHERE [Absence Code] = @AbsenceTransaction
				AND Employee = @Employee
				AND [Start Date] <= @StartDate
				AND [End Date] >= @EndDate
			END
		ELSE IF @AbsenceTransaction = 'Annual Leave'
			BEGIN
				SELECT @NumberofDays = COUNT(Detail)
				FROM [GP SRC Calendar Detail] (NOLOCK)
				WHERE [Date] >= @StartDate
				AND [Date] <= @EndDate
				AND [Day Type] NOT IN ('Holiday', 'Weekend')
				AND [Calendar] = @UseCalendarDetail

				SET @RequestCount = @NumberofDays
			END

		IF @IsValid = 1 AND @AbsenceTransaction = 'Annual Leave' AND @Balance < @RequestCount 
		BEGIN
			SET @IsValid = 0
			SET @ErrorLevel = 8
			SET @ErrorMaxDays = @Balance
		END

		IF @IsValid = 1
			BREAK 

		FETCH NEXT FROM leave_rule_cursor
		INTO @RuleCode,
		@MinServicePeriodRule,
		@MaxServicePeriodRule,
		@ExpatRule,
		@GenderRule,
		@ReligionRule,
		@MaritalStatusRule,
		@GradeRule,
		@ProbationRule,
		@MinDateDiffRule,
		@MaxDateDiffRule,
		@UseCalendarDetail,
		@MaxDays,
		@MaxRequests,
		@NumRequestUnits,
		@RequestUnits

	END

	CLOSE leave_rule_cursor
	DEALLOCATE leave_rule_cursor

	IF @ErrorLevel = 0
		RETURN
	ELSE
	BEGIN
		
		DECLARE @ErrorMsg nvarchar(500)

		SET @ErrorMsg = CASE @ErrorLevel WHEN 1 THEN 'The request did not match the Service Period requirementrs for this Leave Type. Please confirm the validity of the request with HR.'
										 WHEN 2 THEN 'This Leave Type may not be available to you or did not match any rules defined for it. Please confirm the validity of the request with HR.'
										 WHEN 3 THEN 'You can only request a leave of this type at least ' + ISNULL(CAST(@ErrorDateDiff as nvarchar(5)),'N/A') + ' days before the actual leave date. Please select a later date and try again.'
										 WHEN 4 THEN 'You can only request a leave of this type at most ' + ISNULL(CAST(@ErrorDateDiff as nvarchar(5)),'N/A') + ' days before the actual leave date. Please select an earlier date and try again.'
										 WHEN 5 THEN 'The request exceeds the maximum number (' + ISNULL(CAST(@ErrorMaxDays as nvarchar(5)),'N/A') + ') of days defined for this Leave Type. Please select a shorter period and try again.'
										 WHEN 6 THEN 'This Leave Type has already been taken previously and cannot be requested again. Please contact HR for Leave Policy clarifications.'
										 WHEN 7 THEN 'This request would exceed the allowable request rate for this Leave Type. Please contact HR for Leave Policy clarifications.'
										 WHEN 8 THEN 'The request is more than the remaining balance of (' + ISNULL(CAST(@ErrorMaxDays as nvarchar(5)),'N/A') + ') day for this type of leave. Please select a shorter period and try again.'
										 ELSE 'This request is invalid according to configured Leave Rules defined for this Leave Type. Please contact HR for Leave Policy clarifications.' END

		RAISERROR(@ErrorMsg, 16, 1)
		RETURN
										 
	END

		--IF(@ProbationRule = 'No')
		--BEGIN
		--	IF(@StartDate <= @probationdate)
		--	BEGIN
		--		RAISERROR ('Employee can''t apply for this leave during probation period. Please verify your data and try again.',16,1)
		--		RETURN
		--	END
		--END

		--IF(UPPER(@ReligionRule) <> UPPER(@Religion))
		--BEGIN
		--	RAISERROR ('This leave is not available for your religion. Please verify your data and try again.',16,1)
		--	RETURN
		--END

		--IF(@ReligionRule = 'Haj Leave' AND @Religion <> 'Muslim')
		--BEGIN
		--	RAISERROR ('Haj Leave is granted to Muslim employees for the purpose of performing Haj. Employees can apply for Haj Leave once during employment period. Please verify your data and try again.',16,1)
		--	RETURN
		--END

		--IF(@GenderRule = 'Female' AND @Gender <> 'Female')
		--BEGIN
		--	RAISERROR ('This leave is only granted to female employee. Please verify your data and try again.',16,1)
		--	RETURN
		--END

		--IF(@GenderRule = 'Male' AND @GENDER <> 'Male')
		--BEGIN
		--	RAISERROR ('This leave is only granted to male employee. Please verify your data and try again.',16,1)
		--	RETURN
		--END

GO


--EXEC [Validate Leave Request] 8068,'Annual Leave','1 Jul 2024','2 Jul 2024','No',Null,'REQUESTED','No',Null,Null,'No'