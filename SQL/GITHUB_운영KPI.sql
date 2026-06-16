WITH cc_final AS (
    SELECT C.*
    FROM cc_raw C
    JOIN (
        SELECT 
            product_id, 
            location, 
            MAX(최종차수) AS max_최종차수
        FROM cc_raw
        GROUP BY product_id, location
    ) M 
        ON C.product_id = M.product_id 
       AND C.location = M.location 
       AND C.최종차수 = M.max_최종차수
),

cc_pivot AS (
    SELECT 
        product_id,
        location,
        MAX(CASE WHEN 최종차수 = 1 THEN final_real_qty END) AS cc1_qty,
        MAX(CASE WHEN 최종차수 = 1 THEN worker_id END) AS cc1_worker,
        MAX(CASE WHEN 최종차수 = 2 THEN final_real_qty END) AS cc2_qty,
        MAX(CASE WHEN 최종차수 = 2 THEN worker_id END) AS cc2_worker,
        MAX(CASE WHEN 최종차수 = 3 THEN final_real_qty END) AS cc3_qty,
        MAX(CASE WHEN 최종차수 = 3 THEN worker_id END) AS cc3_worker
    FROM cc_raw
    GROUP BY product_id, location
),

detailed_quality_raw AS (
    SELECT
        S.location,
        S.product_id,
        S.start_worktime,
        S.final_worktime,
        C.`최종 작업시간`,
        CASE
            WHEN S.qty_result = '정상' THEN '정상(종료)'
            
            WHEN S.qty_result = '불일치' 
                 AND C.cc_status = '1차확정' 
                 AND C.final_real_qty = S.real_qty 
            THEN '정상(종료)'
            
            WHEN S.qty_result = '불일치' 
                 AND COALESCE(P.cc3_qty, P.cc2_qty, P.cc1_qty) = S.system_qty 
            THEN 'SBC오류'
            
            WHEN (C.cc_status = '2차확정' AND P.cc2_qty <> P.cc1_qty AND P.cc2_qty = S.real_qty)
              OR (C.cc_status = '3차확정' AND P.cc3_qty = P.cc2_qty AND P.cc3_qty <> P.cc1_qty)
            THEN 'CC1차_오류'
            
            WHEN C.cc_status = '3차확정' 
                 AND P.cc3_qty = P.cc1_qty 
                 AND P.cc3_qty <> P.cc2_qty
            THEN 'CC2차_오류'
            
            WHEN C.cc_status = '3차확정' 
                 AND P.cc3_qty <> P.cc1_qty 
                 AND P.cc3_qty <> P.cc2_qty 
                 AND P.cc1_qty <> P.cc2_qty
            THEN '다중_연쇄오류'
            
            ELSE '검토필요'
        END AS 판정_상세유형
    FROM sbc_raw S
    LEFT JOIN cc_final C 
        ON S.location = C.location 
       AND S.product_id = C.product_id
    LEFT JOIN cc_pivot P 
        ON S.location = P.location 
       AND S.product_id = P.product_id
),

time_metrics AS (
    SELECT
        판정_상세유형,
        CASE
            WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') AND `최종 작업시간` IS NOT NULL
            THEN TIMESTAMPDIFF(SECOND, start_worktime, `최종 작업시간`)
            ELSE TIMESTAMPDIFF(SECOND, start_worktime, final_worktime)
        END AS duration_sec
    FROM detailed_quality_raw
)

SELECT
    ROUND(AVG(CASE WHEN 판정_상세유형 = '정상(종료)' THEN duration_sec END), 1) AS 정상건_평균소요시간,
    ROUND(AVG(CASE WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') THEN duration_sec END), 1) AS 오류건_평균소요시간,
    COUNT(CASE WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') THEN 1 END) AS 실오류_확정건수,
    
    ROUND(
        AVG(CASE WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') THEN duration_sec END) - 
        AVG(CASE WHEN 판정_상세유형 = '정상(종료)' THEN duration_sec END), 
        1
    ) AS 오류1건당_지연시간, 
    
    ROUND(
        ((AVG(CASE WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') THEN duration_sec END) - 
          AVG(CASE WHEN 판정_상세유형 = '정상(종료)' THEN duration_sec END)) * COUNT(CASE WHEN 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류') THEN 1 END)) / 3600, 
        2
    ) AS 오류로_인한_총_실시간
FROM time_metrics;