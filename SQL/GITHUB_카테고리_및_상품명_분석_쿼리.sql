WITH cc_final AS (

    SELECT C.*
    FROM cc_raw C
    JOIN (
        SELECT product_id, location, MAX(최종차수) AS max_최종차수
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
        S.location AS 로케이션,
        S.product_id AS 상품ID,
        S.product_name AS 상품명, 
        C.category AS 카테고리,
        
        -- 1. 책임 작업자 정의
        CASE
            WHEN S.qty_result = '불일치' 
                 AND COALESCE(P.cc3_qty, P.cc2_qty, P.cc1_qty) = S.system_qty
            THEN S.worker_id
    
             -- [CC 1차 과실] 2차 확정인데 2차 수량이 1차와 다르고 SBC 실물과 같다면 1차 오류
            WHEN C.cc_status = '2차확정' 
                 AND P.cc2_qty <> P.cc1_qty 
                 AND P.cc2_qty = S.real_qty
            THEN P.cc1_worker

             -- [CC 1차 과실] 3차까지 갔는데 3차 수량이 2차 수량과 같다면 1차 오류
            WHEN C.cc_status = '3차확정' 
                 AND P.cc3_qty = P.cc2_qty 
                 AND P.cc3_qty <> P.cc1_qty
            THEN P.cc1_worker

             -- [CC 2차 과실] 3차까지 갔는데 3차 수량이 1차 수량과 같다면 2차 오류
            WHEN C.cc_status = '3차확정' 
                 AND P.cc3_qty = P.cc1_qty 
                 AND P.cc3_qty <> P.cc2_qty
            THEN P.cc2_worker
            
            WHEN S.qty_result = '불일치' AND C.cc_status IS NOT NULL 
            THEN C.worker_id
            
            ELSE S.worker_id
        END AS responsibility_worker_id,



    
        -- 2.판정_상세유형
        CASE
            -- 정상 건 통과
            WHEN S.qty_result = '정상' THEN '정상(종료)'
            -- SBC 불일치
            WHEN S.qty_result = '불일치' AND C.cc_status = '1차확정' AND C.final_real_qty = S.real_qty 
            THEN '정상(종료)'

            -- SBC 오판정 
            WHEN S.qty_result = '불일치' 
                 AND COALESCE(P.cc3_qty, P.cc2_qty, P.cc1_qty) = S.system_qty 
            THEN 'SBC오류'

            -- CC 1차 작업자의 오판정
            WHEN (C.cc_status = '2차확정' AND P.cc2_qty <> P.cc1_qty AND P.cc2_qty = S.real_qty)
              OR (C.cc_status = '3차확정' AND P.cc3_qty = P.cc2_qty AND P.cc3_qty <> P.cc1_qty)
            THEN 'CC1차_오류'

             -- CC 2차 작업자의 오판정
            WHEN C.cc_status = '3차확정' AND P.cc3_qty = P.cc1_qty AND P.cc3_qty <> P.cc2_qty
            THEN 'CC2차_오류'

             -- 1,2,3차가 전부 수량이 다른 상태 (해당 상품 진열 분산 및 다중 오판정)
            WHEN C.cc_status = '3차확정' AND P.cc3_qty <> P.cc1_qty AND P.cc3_qty <> P.cc2_qty AND P.cc1_qty <> P.cc2_qty
            THEN '복합오류'
            
            ELSE '검토필요'
        END AS 판정_상세유형
    FROM sbc_raw S
    LEFT JOIN cc_final C ON S.location = C.location AND S.product_id = C.product_id
    LEFT JOIN cc_pivot P ON S.location = P.location AND S.product_id = P.product_id
),

category_summary AS (
    SELECT 
        카테고리,
        상품명,
        COUNT(DISTINCT CONCAT(로케이션, '|', 상품ID)) AS 오류_발생건수
    FROM detailed_quality_raw
    WHERE 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '복합오류')
    GROUP BY 
        카테고리,
        상품명
)

-- 파레토 구성비율 
SELECT 
    카테고리,
    상품명,
    오류_발생건수,
    ROUND(
        오류_발생건수 * 100.0
        / NULLIF(SUM(오류_발생건수) OVER(), 0),
        2
    ) AS 구성비율_퍼센트
FROM category_summary
ORDER BY 
    오류_발생건수 DESC,
    카테고리 ASC;
