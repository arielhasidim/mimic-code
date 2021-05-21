-- Author: Ariel Hasidim, April 17th 2021

-- "FLUID BALANCE CHART" is used for estimating 24hr balance and is not very accurate to the hour. It does not account 
-- for insensible losses. Secondly, documentation errors are common. Moreover, the spot outputs are joined 
-- approximately and does not represent the kinetics properly.
-- 1. Shepherd E. Why are fluid balance charts notoriously difficult to maintain accurately? [Internet]. Nursing Times. 2011 [cited 2021 Apr 17]. Available from: https://www.nursingtimes.net/opinion/why-are-fluid-balance-charts-notoriously-difficult-to-maintain-accurately-18-07-2011/
-- 2. Fluid balance • LITFL • CCC resuscitation [Internet]. Life in the Fast Lane • LITFL. 2019 [cited 2021 Apr 17]. Available from: https://litfl.com/fluid-balance/

-- RATIONAL: (1) Volume inputs (identified with L/mL units) are given continuously in steady rate 
-- by default, and has start/end time so that summing rate_in per time interval is simple.
-- (2) Output events are more complicated: (2a) Most volume outputs composed of urine output events, 
-- can be assumed as "back-to-back" and can be translated to rate_out with chartevents as start/end times.
-- (2b) Other output volumes cannot simply translated to rate, and are added as a spot outputs amounts by 
-- charttime to the corresponding interval.

-- Create table with all volume inputs (amountuom = 'l' or 'ml') from inputevents and generate rate_in pre input
WITH fluid_in_all AS (
  SELECT stay_id, starttime, endtime, 
  CASE
    WHEN LOWER(amountuom) LIKE 'ml' THEN amount
    ELSE amount * 1000
  END AS amount,
  CASE
    WHEN LOWER(amountuom) LIKE 'ml' THEN amount
    ELSE amount * 1000
  END / (DATETIME_DIFF(endtime, starttime, SECOND) / 3600) AS rate_in
  FROM `physionet-data.mimic_icu.inputevents` 
  WHERE LOWER(amountuom) IN('l', 'ml') AND amount > 0
),

-- Break all fluid_in to time intervales before summing rates in each interval
fluid_in_intervales AS (
 SELECT distinct s.stay_id, s.starttime, MIN(e.endtime) endtime FROM 
 (SELECT stay_id, starttime FROM fluid_in_all
  UNION DISTINCT
  SELECT stay_id, endtime AS starttime FROM fluid_in_all) s
  LEFT JOIN
   (SELECT stay_id, starttime AS endtime FROM fluid_in_all
    UNION DISTINCT
    SELECT stay_id, endtime from fluid_in_all) e ON e.stay_id = s.stay_id 
      AND e.endtime > s.starttime
  GROUP BY s.stay_id, s.starttime
),

-- Fluids rate_in is summed in each interval
fluid_in_intervales_summed AS (
  SELECT a.stay_id, a.starttime, a.endtime, SUM(rate_in) rate_in
  FROM fluid_in_intervales a
  LEFT JOIN fluid_in_all b ON b.stay_id = a.stay_id
    AND b.starttime < a.endtime
    AND b.endtime > a.starttime
  GROUP BY a.stay_id, a.starttime, a.endtime
),

-- Urineoutputs are translated to rates
-- Based on `mimic_derived.urine_output` and theoreticly can be generated localy.
urine_out AS (
  SELECT a.stay_id, a.charttime AS starttime,
  MIN(b.charttime) AS endtime,
  a.urineoutput AS amount
  FROM `physionet-data.mimic_derived.urine_output` a
  LEFT JOIN `physionet-data.mimic_derived.urine_output` b ON b.stay_id = a.stay_id 
    AND b.charttime > a.charttime
  GROUP BY a.stay_id, a.charttime, a.urineoutput
),

-- Calculate urine rate
urine_out_with_rate AS (
  SELECT *, amount / (DATETIME_DIFF(endtime, starttime, SECOND) / 3600) AS rate_out_urine
  FROM urine_out
),

-- Create datetime list from all start/end time of all ins/outs as preparation for creating combined time intervals
-- and then create time intervals
datetime_list AS (
  SELECT distinct stay_id, datetime FROM
    ((SELECT stay_id, starttime datetime FROM fluid_in_intervales_summed
    UNION DISTINCT
    SELECT stay_id, endtime datetime FROM fluid_in_intervales_summed) 
      UNION DISTINCT
    (SELECT stay_id, starttime datetime FROM urine_out
    UNION DISTINCT
    SELECT stay_id, endtime datetime FROM urine_out)) AS a
  WHERE datetime IS NOT NULL
),
intervals AS (
  SELECT a.stay_id, a.datetime starttime, MIN(b.datetime) endtime 
  FROM datetime_list a
  LEFT JOIN datetime_list b ON b.stay_id = a.stay_id 
    AND b.datetime > a.datetime
  GROUP BY a.stay_id, a.datetime
),

-- Sum up all rate_in and rate_out_urine in time intervales
-- Also round up rates and cange null rates to 0
summed_rates AS (
  SELECT a.stay_id, a.starttime, a.endtime, 
    CASE
      WHEN b.rate_in IS NULL THEN 0
      ELSE ROUND(b.rate_in)
    END rate_in, 
    CASE
      WHEN c.rate_out_urine IS NULL THEN 0
      ELSE ROUND(c.rate_out_urine)
    END AS rate_out_urine
  FROM intervals a
  LEFT JOIN fluid_in_intervales_summed b ON b.stay_id = a.stay_id
    AND b.starttime < a.endtime
    AND b.endtime > a.starttime
  LEFT JOIN urine_out_with_rate c ON c.stay_id = a.stay_id
    AND c.starttime < a.endtime
    AND c.endtime > a.starttime
  ORDER BY stay_id, starttime
),

-- Create table with all spot outputs amounts and round time to closest time interval (ceiling)
spot_outputs AS (
  SELECT a.stay_id, MIN(b.datetime) charttime_ceiled, a.itemid, 
    CASE
      WHEN a.value IS NULL THEN 0
      ELSE a.value
    END AS value
  FROM `physionet-data.mimic_icu.outputevents` a 
  LEFT JOIN datetime_list b on a.stay_id = b.stay_id
   AND a.charttime < b.datetime
  WHERE a.itemid IN
    (
      226627, -- operating room Urine
      226588, 226589, 229413, 229414, 226619, 226590, 226593, 226592, 226620, -- Chest Tubes/Pleural/Mediastinal/Pigtail
      226633, -- Pre-Admission
      226626, -- operating room estimated blood loss
      226575, 226576, 226573, -- Nasogastric, Oral Gastric, Gastric Tube
      226580, -- Fecal Bag
      226579, -- Stool
      226599, 226600, 226601, 226602, 226597, -- Jackson Pratts
      226582, 226574, -- Ostomy/Jejunostomy
      227510, -- Tube Feeding Residual
      226613, 226614, 226604, 226605, 226617,226618, 226623, 226624, -- Wound Vac/Hemovac/Sump/Penrose
      226583,  -- Rectal Tube
      226631, 226628, 226629, 226630,  -- post-anesthesia care unit urine/drain/estimated blood loss/gastric
      227701,  -- Drainage Bag
      226571,  -- Emesis
      226606, 226607,  -- Cerebral Ventricular
      226632, -- Cath Lab
      226612, -- Pericardial
      226603, -- T tube
      226610 -- Lumbar
    )
  GROUP BY a.stay_id, a.itemid, a.value 
)


SELECT a.stay_id, a.starttime, a.endtime, a.rate_in, a.rate_out_urine, SUM(b.value) spot_out_amount,
  (rate_in * (datetime_diff(endtime, starttime, second) / 3600) - 
   rate_out_urine * (datetime_diff(endtime, starttime, second) / 3600) +
   CASE
     WHEN SUM(b.value) IS NULL THEN 0
     ELSE SUM(b.value)
   END
   ) / (datetime_diff(endtime, starttime, second) / 3600)
  AS rate_all
FROM summed_rates a
LEFT JOIN spot_outputs b ON b.stay_id = a.stay_id 
  AND b.charttime_ceiled = a.starttime
GROUP BY a.stay_id, a.starttime, a.endtime, a.rate_in, a.rate_out_urine
ORDER BY stay_id, starttime