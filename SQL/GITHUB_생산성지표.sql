WITH performance_cte AS (
    -- CC 작업 집계
    SELECT
        C.worker_id,
        COALESCE(W.name, C.worker_id) AS 작업자이름,
        C.location,
        C.product_id,
        C.final_real_qty AS 작업양,
        TIMESTAMPDIFF(
            MINUTE,
            C.`1차 작업시간`,
            C.`최종 작업시간`
        ) AS 소요시간_분
    FROM cc_raw C
    LEFT JOIN workers W ON C.worker_id = W.worker_id

    UNION ALL

    -- SBC 작업 집계
    SELECT
        S.worker_id,
        COALESCE(W.name, S.worker_id) AS 작업자이름,
        S.location,
        S.product_id,
        S.real_qty AS 작업양,
        TIMESTAMPDIFF(
            MINUTE,
            S.start_worktime,
            S.final_worktime
        ) AS 소요시간_분
    FROM sbc_raw S
    LEFT JOIN workers W ON S.worker_id = W.worker_id
),

performance_summary AS (
    SELECT
        worker_id,
        작업자이름,
        SUM(작업양) AS 총_작업양,
        SUM(소요시간_분) AS 총_소요시간_분,
        COUNT(*) AS 전체_작업_건수
    FROM performance_cte
    GROUP BY 
        worker_id,
        작업자이름
),

-- [SBC 불일치부터 CC 1차, 2차, 3차 확정까지의 실물 비교 통제 절]
detailed_quality_raw AS (
    SELECT
        -- 최종 판정 유형에 따라 책임 작업자 ID 배정
        CASE
            -- SBC 오류일 때는 확실하게 SBC 작업자에게 책임 귀속
            WHEN S.qty_result = '불일치' 
                 AND C.cc_status = '1차확정' 
                 AND C.final_real_qty = S.system_qty 
            THEN S.worker_id
            
            -- 그 외 CC 차수(2차, 3차 등)에서 오류가 확정되면 해당 CC 작업자에게 책임 귀속
            ELSE C.worker_id
        END AS responsibility_worker_id,

        -- 차수별 수량 비교를 통한 실질 오류 판정
        CASE
            -- 1. SBC 결과가 정상인 경우 당연히 정상 종료
            WHEN S.qty_result = '정상' 
            THEN '정상(종료)'
            
            -- 2. [전산 오류 필터링] SBC 불일치인데 CC 1차에서 검증하니 SBC 실물과 같을 때 -> 작업자 오류 없음
            WHEN S.qty_result = '불일치' 
                 AND C.cc_status = '1차확정' 
                 AND C.final_real_qty = S.real_qty 
            THEN '정상(종료)'
            
            -- 3. CC 1차에서 전산과 같다고 확정해버렸으나, 실제로는 SBC가 틀린 경우 (SBC 오조작)
            WHEN S.qty_result = '불일치' 
                 AND C.cc_status = '1차확정' 
                 AND C.final_real_qty = S.system_qty 
            THEN 'SBC오류'
                     
            -- 4. CC 2차 확정 시 수량 비교 로직
            WHEN C.cc_status = '2차확정'
                 AND EXISTS (
                     SELECT 1
                     FROM cc_raw C1
                     JOIN cc_raw C2 ON C1.location = C2.location AND C1.product_id = C2.product_id
                     WHERE C1.location = S.location
                       AND C1.product_id = S.product_id
                       AND C1.최종차수 = 1
                       AND C2.최종차수 = 2
                       AND (
                            (C1.final_real_qty = C2.final_real_qty AND S.real_qty <> C2.final_real_qty)
                            OR
                            (S.system_qty = C2.final_real_qty AND C1.final_real_qty <> C2.final_real_qty)
                       )
                 )
            THEN 'CC2차'
                  
            -- 5. [CC 3차 확정 반영] 3차 실물 수량(정답)을 기준으로 앞선 차수들의 과실 판정
            WHEN C.cc_status = '3차확정'
                 AND EXISTS (
                     SELECT 1
                     FROM cc_raw C1
                     JOIN cc_raw C2 ON C1.location = C2.location AND C1.product_id = C2.product_id
                     JOIN cc_raw C3 ON C2.location = C3.location AND C2.product_id = C3.product_id
                     WHERE C1.location = S.location
                       AND C1.product_id = S.product_id
                       AND C1.최종차수 = 1
                       AND C2.최종차수 = 2
                       AND C3.최종차수 = 3
                       AND (
                            -- 조건 A: 3차 실물이 전산과 같음 (SBC, CC1차, CC2차 모두 오조작)
                            (C3.final_real_qty = S.system_qty AND S.real_qty <> C3.final_real_qty AND C1.final_real_qty <> C3.final_real_qty AND C2.final_real_qty <> C3.final_real_qty)
                            OR
                            -- 조건 B: 3차 실물이 1차 실물과 같음 (SBC, CC2차 오조작)
                            (C3.final_real_qty = C1.final_real_qty AND S.system_qty <> C3.final_real_qty AND S.real_qty <> C3.final_real_qty AND C2.final_real_qty <> C3.final_real_qty)
                            OR
                            -- 조건 C: 3차 실물이 2차 실물과 같음 (SBC, CC1차 오조작)
                            (C3.final_real_qty = C2.final_real_qty AND S.system_qty <> C3.final_real_qty AND S.real_qty <> C3.final_real_qty AND C1.final_real_qty <> C3.final_real_qty)
                       )
                 )
            THEN 'CC3차'
            
            ELSE '검토필요'
        END AS 판정_상세유형
    FROM cc_raw C
    LEFT JOIN sbc_raw S 
        ON S.location = C.location 
       AND S.product_id = C.product_id
),

sbc_quality_summary AS (
    -- 실질적인 과실 책임자(responsibility_worker_id) 기준으로 지표 집계
    SELECT
        Q.responsibility_worker_id AS worker_id,
        COUNT(*) AS SBC_작업건수, 
        SUM(CASE 
            WHEN Q.판정_상세유형 IN ('SBC오류', 'CC2차', 'CC3차') 
            THEN 1 ELSE 0 
        END) AS 불일치_건수
    FROM detailed_quality_raw Q
    WHERE Q.responsibility_worker_id IS NOT NULL
    GROUP BY Q.responsibility_worker_id
),

final_summary AS (
    SELECT
        P.worker_id,
        P.작업자이름,
        P.총_작업양,
        P.총_소요시간_분,
        P.전체_작업_건수,

        COALESCE(Q.SBC_작업건수, 0) AS SBC_작업건수,
        COALESCE(Q.불일치_건수, 0) AS 불일치_건수,

        ROUND(
            P.총_작업양 / NULLIF(P.총_소요시간_분 / 60.0, 0), 2
        ) AS 전체_UPH,

        ROUND(
            P.총_소요시간_분 / NULLIF(P.총_작업양, 0), 2
        ) AS 전체_HTP,

        ROUND(
            COALESCE(Q.불일치_건수, 0) * 100.0 / NULLIF(Q.SBC_작업건수, 0), 2
        ) AS 불일치율_퍼센트
    FROM performance_summary P
    LEFT JOIN sbc_quality_summary Q ON P.worker_id = Q.worker_id
)

SELECT
    worker_id,
    작업자이름,
    총_작업양,
    총_소요시간_분,
    전체_UPH,
    전체_HTP,
    SBC_작업건수,
    불일치_건수,
    불일치율_퍼센트,

    RANK() OVER (
        ORDER BY 불일치율_퍼센트 DESC
    ) AS 불일치율_순위,

    CASE
        WHEN 총_작업양 > AVG(총_작업양) OVER () THEN '평균 이상'
        WHEN 총_작업양 < AVG(총_작업양) OVER () THEN '평균 이하'
        ELSE '평균 동일'
    END AS 작업량_평가,

    ROUND(
        SUM(총_작업양) OVER (
            ORDER BY 총_작업양 DESC
        ) * 100.0 / NULLIF(SUM(총_작업양) OVER (), 0), 2
    ) AS 누적_비중_퍼센트,

    CASE
        WHEN 전체_UPH >= AVG(전체_UPH) OVER ()
         AND 불일치율_퍼센트 <= AVG(불일치율_퍼센트) OVER ()
        THEN '핵심성과형'

        WHEN 전체_UPH >= AVG(전체_UPH) OVER ()
         AND 불일치율_퍼센트 > AVG(불일치율_퍼센트) OVER ()
        THEN '품질리스크형'

        WHEN 전체_UPH < AVG(전체_UPH) OVER ()
         AND 불일치율_퍼센트 <= AVG(불일치율_퍼센트) OVER ()
        THEN '안정작업형'

        ELSE '개선필요형'
    END AS 작업자_유형
FROM final_summary
ORDER BY 
    불일치율_순위 DESC,
    불일치율_퍼센트 DESC;
