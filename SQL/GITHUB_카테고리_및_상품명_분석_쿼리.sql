WITH cc_final AS (
    -- [로우 분리 방어] CC 데이터 중 가장 마감된 최종 차수의 행만 1:1 매핑용으로 압축 추출
    SELECT C.*
    FROM cc_raw C
    JOIN (
        SELECT product_name, location, MAX(최종차수) AS max_최종차수
        FROM cc_raw
        GROUP BY product_name, location
    ) M ON C.product_name = M.product_name AND C.location = M.location AND C.최종차수 = M.max_최종차수
),

cc_pivot AS (
    -- [품질 방어] 차수별 수량과 작업자를 한 줄로 펼쳐서 오판정 주범을 명확히 색출
    SELECT 
        product_name,
        location,
        MAX(CASE WHEN 최종차수 = 1 THEN final_real_qty END) AS cc1_qty,
        MAX(CASE WHEN 최종차수 = 1 THEN worker_id END) AS cc1_worker,
        MAX(CASE WHEN 최종차수 = 2 THEN final_real_qty END) AS cc2_qty,
        MAX(CASE WHEN 최종차수 = 2 THEN worker_id END) AS cc2_worker,
        MAX(CASE WHEN 최종차수 = 3 THEN final_real_qty END) AS cc3_qty,
        MAX(CASE WHEN 최종차수 = 3 THEN worker_id END) AS cc3_worker
    FROM cc_raw
    GROUP BY product_name, location
),

detailed_quality_raw AS (
    -- [SBC 중심으로 조인 안전 전환 및 정밀 교정] 
    -- 1:1 관계가 보장된 상태에서 정확한 에러 책임자 및 품질 오류 유형 추출
    SELECT
        S.location AS 로케이션,
        S.product_name AS 상품명,
        C.category AS 카테고리,
        
        -- 1. 책임 작업자 정의 (추후 작업자별 스코어링 연계용으로 보존)
        CASE
            -- [SBC 과실] 최종 마감 수량이 '최초 전산 수량'과 같다면 차수 불문하고 SBC 작업자 과실 100%
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
        
        -- 2. 숙련도 평가용 정밀 판정_상세유형
        CASE
            -- 정상 건 통과
            WHEN S.qty_result = '정상' THEN '정상(종료)'
            
            -- SBC 불일치 적중 (1차 CC가 SBC 실물 수량을 인정함)
            WHEN S.qty_result = '불일치' AND C.cc_status = '1차확정' AND C.final_real_qty = S.real_qty 
            THEN '정상(종료)'
            
            -- SBC 오판정 (최종 수량이 최초 전산과 일치함)
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
            THEN '다중_연쇄오류'
            
            ELSE '검토필요'
        END AS 판정_상세유형
    FROM sbc_raw S
    LEFT JOIN cc_final C ON S.location = C.location AND S.product_name = C.product_name
    LEFT JOIN cc_pivot P ON S.location = P.location AND S.product_name = P.product_name
),

category_summary AS (
    -- 윈도우 함수 분모 꼬임 방지 및 명확한 그룹화를 위한 1차 집계 세션
    SELECT 
        카테고리,
        상품명,
        -- 중복 제거 카운트를 유지하되, 1:1 압축 상태이므로 명확하게 오류 건수 추출
        COUNT(DISTINCT CONCAT(로케이션, '|', 상품명)) AS 오류_발생건수
    FROM detailed_quality_raw
    -- ★ [교정] 수량 대조를 통해 정밀 분석으로 증명된 실질 '작업자 과실 유형'만 필터링
    WHERE 판정_상세유형 IN ('SBC오류', 'CC1차_오류', 'CC2차_오류', '다중_연쇄오류')
    GROUP BY 
        카테고리,
        상품명
)

-- 최종 파레토 구성비율 연산 출력
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
    카테고리 ASC;
