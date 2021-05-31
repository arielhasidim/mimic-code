-- Author: Ariel Hasidim, May 2020

-- # Adjusted urine-ouput MIMIC-IV (Bigquery)
-- Per STAY_ID, for hourly interval, every hour on the hour.
 
-- ## Rationale:
-- This is urine-output adjustment corrected to 1 hour intervals, every hour on the hour.
-- This adjustment is meant to be used for AKI calculation and other research purposes.
-- Each ICUSTAY_ID has "T_PLUS" column that represents the hourly intervals from the beginning to the end of
-- his urine outputevents.

-- The problems with regular urine-outputs in outputevents measurements are:
--  (1) You can have two measurements at one hour interval (e.g. 00:01, 00:59).
--  (2) Different time interval between measurements.
-- Since urine collection is done per unit of time from the last measurement, every value should be 
-- corrected for the time length it represents.

-- ### SUMMARY OF THE SOLUTION:
-- The solution is summing up:
--  1st sample in the interval - is multiplied by the portion of time within the interval to the full length of time.
--  1st sample of the NEXT interval  - is multiplied by the portion of time within the interval to the full length of time.
--  Other samples in the interval - simply added.

-- An hour interval without measurement within, and without measurement 2 hours before or after is defined "null".

-- ### Negative urine-outpus values:
-- Because of irregularities with irrigation in/out (`ITEMID`s: 227488/227489) that in my opinion cannot be sufficiently 
-- clarified for research purposes, and because only 288/55,077 `ICUSTAY_ID`s in mimic-iii contain this values, I suggest 
-- excluding these `ICUSTAY_ID`s in urine-ouput based researches. 
-- Suggested exclusion list is appended in the file "exclusion_icustays.csv", and was generated with this query:
    -- SELECT ICUSTAY_ID
    -- FROM `physionet-data.mimiciii_clinical.outputevents`
    -- where ITEMID = 227488 OR ITEMID = 227489
    -- group by ICUSTAY_ID
-- see [#745](https://github.com/MIT-LCP/mimic-code/issues/745) for further discussion.

WITH uo AS (
-- relevant urine-ouput columns
  SELECT STAY_ID, CHARTTIME, VALUE, 
  --   CIS method
   If(oe.itemid < 50000, "CareVue", "MetaVision") as CIS
  FROM (
      select SUBJECT_ID, HADM_ID, oe.stay_id, CHARTTIME, ITEMID 
      , SUM(
          -- we consider input of GU irrigant as a negative volume
          case when oe.itemid = 227488 then -1*value
          else value end
        ) as VALUE,
        STORETIME
      from `physionet-data.mimic_icu.outputevents`  oe
      where oe.itemid in
      (
        -- these are the most frequently occurring urine output observations in CareVue
        40055, -- "Urine Out Foley"
        43175, -- "Urine ."
        40069, -- "Urine Out Void"
        40094, -- "Urine Out Condom Cath"
        40715, -- "Urine Out Suprapubic"
        40473, -- "Urine Out IleoConduit"
        40085, -- "Urine Out Incontinent"
        40057, -- "Urine Out Rt Nephrostomy"
        40056, -- "Urine Out Lt Nephrostomy"
        40405, -- "Urine Out Other"
        40428, -- "Urine Out Straight Cath"
        40086,--	Urine Out Incontinent
        40096, -- "Urine Out Ureteral Stent #1"
        40651, -- "Urine Out Ureteral Stent #2"

        -- these are the most frequently occurring urine output observations in MetaVision
        226559, -- "Foley"
        226560, -- "Void"
        226561, -- "Condom Cath"
        226584, -- "Ileoconduit"
        226563, -- "Suprapubic"
        226564, -- "R Nephrostomy"
        226565, -- "L Nephrostomy"
        226567, --	Straight Cath
        226557, -- R Ureteral Stent 
        226558, -- L Ureteral Stent
        227488, -- GU Irrigant Volume In
        227489  -- GU Irrigant/Urine Volume Out
      ) 
      and oe.value < 5000 -- sanity check on urine value
      and oe.stay_id  is not null 
      group by SUBJECT_ID, HADM_ID, oe.stay_id, CHARTTIME, ITEMID, STORETIME) oe 
  GROUP BY STAY_ID, CHARTTIME, VALUE, oe.itemid
  ORDER BY STAY_ID, charttime asc
), 
RAW_ARRAY_OF_TIMES AS (
-- array of numbers that represent total hours measured for specific STAY_ID + start-time rounded down
  SELECT STAY_ID, GENERATE_ARRAY(1, DATETIME_DIFF(max(uo.charttime), min(uo.charttime), hour) - 1, 1) ary, 
    DATETIME_TRUNC(min(uo.charttime), HOUR)  start_time_rounded_up,
    DATETIME_TRUNC(max(uo.charttime), HOUR)  end_time_rounded_up,
    DATETIME_DIFF(max(uo.charttime), min(uo.charttime), hour) time_diff
  FROM uo
  GROUP BY STAY_ID
),
LISTED_ARRAY_OF_TIMES AS (
  SELECT * FROM RAW_ARRAY_OF_TIMES CROSS JOIN UNNEST(ary) as T_PLUS
  ORDER BY STAY_ID, T_PLUS
),
TIMES_WITH_INTERVALS AS (
-- total hours list + absolute time intervals + uo.charttime array for every row
  SELECT laot.STAY_ID, laot.T_PLUS, laot.START_TIME_ROUNDED_UP,
    DATETIME_ADD(start_time_rounded_up, INTERVAL T_PLUS HOUR) as TIME_INTERVAL_STARTS,
    DATETIME_ADD(start_time_rounded_up, INTERVAL T_PLUS + 1 HOUR) as TIME_INTERVAL_FINISH,
--     ARRAY(SELECT x FROM UNNEST(ARRAY((select charttime from uo where uo.STAY_ID = laot.STAY_ID))) AS x ORDER BY x) AS ca,
  FROM LISTED_ARRAY_OF_TIMES laot
  GROUP BY laot.T_PLUS, laot.STAY_ID, laot.START_TIME_ROUNDED_UP, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH
  ORDER BY laot.STAY_ID, laot.T_PLUS
),
INTERVALS_WITH_TIMES_AND_UO AS (
-- count how many urine-output chart-events for every hourly interval, specify datetime. 
-- also adds last datetime event before the interval + first event after: datetime and value
---- ALL THE MINIMAL NEEDS FOR THE ADJUSTED CALCULATION IS PRESENT. ----
  SELECT twi.STAY_ID, T_PLUS, START_TIME_ROUNDED_UP, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH,
    COUNT(case when (uo.charttime BETWEEN twi.TIME_INTERVAL_STARTS AND twi.TIME_INTERVAL_FINISH) AND 
      (uo.STAY_ID = twi.STAY_ID) then uo.charttime end) 
      AS NUMBER_OF_OUTPUTS_IN_INTERVAL,
    ARRAY_AGG(case when (uo.charttime BETWEEN twi.TIME_INTERVAL_STARTS AND twi.TIME_INTERVAL_FINISH) AND 
      (uo.STAY_ID = twi.STAY_ID) then uo.charttime end IGNORE NULLS ORDER BY uo.charttime)
      AS ARRAY_OF_TIMES_IN_INTERVALL,
    ARRAY_AGG(case when (uo.charttime BETWEEN twi.TIME_INTERVAL_STARTS AND twi.TIME_INTERVAL_FINISH) AND 
      (uo.STAY_ID = twi.STAY_ID) then uo.value end IGNORE NULLS ORDER BY uo.charttime) 
      AS ARRAY_OF_UO,
    ARRAY_REVERSE(ARRAY_AGG(case when (uo.charttime <= twi.TIME_INTERVAL_STARTS) AND 
      (uo.STAY_ID = twi.STAY_ID) then uo.charttime end IGNORE NULLS ORDER BY uo.charttime))[OFFSET(0)] 
      AS TIME_BEFORE,
    ARRAY_AGG(case when (uo.charttime > twi.TIME_INTERVAL_FINISH) AND 
      (uo.STAY_ID = twi.STAY_ID) then uo.charttime end IGNORE NULLS ORDER BY uo.charttime)[OFFSET(0)] 
      AS TIME_AFTER,
    ARRAY_AGG(case when (uo.charttime > twi.TIME_INTERVAL_FINISH) 
      AND (uo.STAY_ID = twi.STAY_ID) then uo.value end IGNORE NULLS ORDER BY uo.charttime)[OFFSET(0)] 
      AS UO_AFTER,
  FROM TIMES_WITH_INTERVALS twi 
    LEFT JOIN uo
    ON uo.STAY_ID = twi.STAY_ID
  GROUP BY twi.STAY_ID, T_PLUS, START_TIME_ROUNDED_UP, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH
  ORDER BY twi.STAY_ID, T_PLUS
),
CALCULATION_BOARD1 AS (
-- calculations step 1
  SELECT STAY_ID, T_PLUS, START_TIME_ROUNDED_UP, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH, NUMBER_OF_OUTPUTS_IN_INTERVAL, ARRAY_OF_TIMES_IN_INTERVALL, ARRAY_OF_UO,
    IFNULL((SELECT SUM(s) FROM UNNEST(ARRAY_OF_UO) s), (0)) SIMPLE_SUM,
    TIME_BEFORE,
    IFNULL((DATETIME_DIFF(ARRAY_OF_TIMES_IN_INTERVALL[OFFSET(0)], TIME_INTERVAL_STARTS, minute)), (0)) MINUTES_BEFORE_INTERVAL,
    DATETIME_DIFF(TIME_INTERVAL_STARTS, TIME_BEFORE, minute) MINUTES_BEFORE_TOTAL,
    TIME_AFTER,
    UO_AFTER,
    IFNULL((DATETIME_DIFF(TIME_INTERVAL_FINISH, ARRAY_REVERSE(ARRAY_OF_TIMES_IN_INTERVALL)[OFFSET(0)], minute)), (60)) MINUTES_AFTER_INTERVAL,
    DATETIME_DIFF(TIME_AFTER, TIME_INTERVAL_FINISH, minute) MINUTES_AFTER_TOTAL,
  FROM INTERVALS_WITH_TIMES_AND_UO
  ORDER BY STAY_ID, T_PLUS
),
CALCULATION_BOARD2 AS (
-- calculations step 2
  SELECT *,
    (CASE WHEN (MINUTES_BEFORE_TOTAL IS NULL) OR (MINUTES_BEFORE_TOTAL = 0) THEN 0 ELSE 
      MINUTES_BEFORE_INTERVAL / (MINUTES_BEFORE_TOTAL + MINUTES_BEFORE_INTERVAL)
    END) FIRST_UO_PORTION,
    (CASE WHEN NUMBER_OF_OUTPUTS_IN_INTERVAL = 0 
      THEN 60 / DATETIME_DIFF(TIME_AFTER, TIME_BEFORE, MINUTE) ELSE
      (CASE WHEN (MINUTES_AFTER_TOTAL IS NULL) OR (MINUTES_AFTER_TOTAL = 0) THEN 0 ELSE 
        MINUTES_AFTER_INTERVAL / (MINUTES_AFTER_TOTAL + MINUTES_AFTER_INTERVAL)
        END)
    END) AFTER_UO_PORTION
  FROM CALCULATION_BOARD1
  ORDER BY STAY_ID, T_PLUS
),
FINAL_CALC AS (
-- calculations step 3 (FINAL)
-- all the steps for all the calculation present for quality chck
  SELECT *,
    CAST(
      IF (((NUMBER_OF_OUTPUTS_IN_INTERVAL = 0) AND DATETIME_DIFF(TIME_AFTER, TIME_BEFORE, MINUTE) / 60 > 12),
      NULL,    
        (IFNULL((SELECT SUM(s) FROM UNNEST(ARRAY_OF_UO) s), (0))) - (IFNULL((ARRAY_OF_UO[OFFSET(0)]), (0))) +
        ((IFNULL((ARRAY_OF_UO[OFFSET(0)]), (0))) * (IFNULL(FIRST_UO_PORTION, 0))) +
        ((IFNULL(UO_AFTER, 0)) * (IFNULL(AFTER_UO_PORTION, 0)))
      )
    AS INT64) ADJUSTED_SUM
  FROM CALCULATION_BOARD2
  ORDER BY STAY_ID, T_PLUS
),
SUMMARY AS (
-- minimal summary
  SELECT STAY_ID, T_PLUS, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH, SIMPLE_SUM, ADJUSTED_SUM
  FROM FINAL_CALC
  ORDER BY STAY_ID, T_PLUS
)

SELECT s.*, p.weight_admit FROM SUMMARY s
LEFT JOIN `physionet-data.mimic_derived.first_day_weight`   p
  ON s.STAY_ID = p.STAY_ID 
GROUP BY STAY_ID, T_PLUS, TIME_INTERVAL_STARTS, TIME_INTERVAL_FINISH, SIMPLE_SUM, ADJUSTED_SUM, weight_admit
ORDER BY s.STAY_ID, T_PLUS
