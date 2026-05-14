WITH performance_cte AS (

    -- CC 작업 성과 집계
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
    LEFT JOIN workers W
        ON C.worker_id = W.worker_id

    UNION ALL

    -- SBC 작업 성과 집계
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
    LEFT JOIN workers W
        ON S.worker_id = W.worker_id
),

-- 정밀 재고조사 오류 집계
error_cte AS (

    SELECT
        CASE
            WHEN S.qty_result = '불일치'
             AND C.final_real_qty = S.system_qty
            THEN S.worker_id
            ELSE C.worker_id
        END AS worker_id,

        CASE
            WHEN S.qty_result = '불일치'
             AND C.final_real_qty = S.system_qty
            THEN COALESCE(W_sbc.name, S.worker_id)
            ELSE COALESCE(W_cc.name, C.worker_id)
        END AS 작업자이름,

        C.location,
        C.product_id,

        CASE
            WHEN S.qty_result = '정상'
            THEN '정상(종료)'

            WHEN S.qty_result = '불일치'
             AND C.cc_status = '1차확정'
             AND C.final_real_qty = S.real_qty
            THEN '정상(종료)'

            WHEN S.qty_result = '불일치'
             AND C.cc_status = '1차확정'
             AND C.final_real_qty = S.system_qty
            THEN 'SBC오류'

            WHEN C.cc_status = '2차확정'
             AND EXISTS (
                SELECT 1
                FROM cc_raw C1
                JOIN cc_raw C2
                    ON C1.location = C2.location
                   AND C1.product_id = C2.product_id
                WHERE C1.location = S.location
                  AND C1.product_id = S.product_id
                  AND C1.최종차수 = 1
                  AND C2.최종차수 = 2
                  AND (
                        (
                            C1.final_real_qty = C2.final_real_qty
                            AND S.real_qty <> C2.final_real_qty
                        )
                        OR
                        (
                            S.system_qty = C2.final_real_qty
                            AND C1.final_real_qty <> C2.final_real_qty
                        )
                  )
            )
            THEN 'CC2차'

            WHEN C.cc_status = '3차확정'
             AND EXISTS (
                SELECT 1
                FROM cc_raw C1
                JOIN cc_raw C2
                    ON C1.location = C2.location
                   AND C1.product_id = C2.product_id
                JOIN cc_raw C3
                    ON C2.location = C3.location
                   AND C2.product_id = C3.product_id
                WHERE C1.location = S.location
                  AND C1.product_id = S.product_id
                  AND C1.최종차수 = 1
                  AND C2.최종차수 = 2
                  AND C3.최종차수 = 3
                  AND (
                        (
                            C3.final_real_qty = S.system_qty
                            AND S.real_qty <> C3.final_real_qty
                            AND C1.final_real_qty <> C3.final_real_qty
                            AND C2.final_real_qty <> C3.final_real_qty
                        )
                        OR
                        (
                            C3.final_real_qty = C1.final_real_qty
                            AND S.system_qty <> C3.final_real_qty
                            AND S.real_qty <> C3.final_real_qty
                            AND C2.final_real_qty <> C3.final_real_qty
                        )
                        OR
                        (
                            C3.final_real_qty = C2.final_real_qty
                            AND S.system_qty <> C3.final_real_qty
                            AND S.real_qty <> C3.final_real_qty
                            AND C1.final_real_qty <> C3.final_real_qty
                        )
                  )
            )
            THEN 'CC3차'

            ELSE '검토필요'
        END AS 판정_상세유형

    FROM cc_raw C

    LEFT JOIN sbc_raw S
        ON S.location = C.location
       AND S.product_id = C.product_id

    LEFT JOIN workers W_sbc
        ON S.worker_id = W_sbc.worker_id

    LEFT JOIN workers W_cc
        ON C.worker_id = W_cc.worker_id
),

performance_summary AS (

    SELECT
        worker_id,
        작업자이름,
        SUM(작업양) AS 총_작업양,
        SUM(소요시간_분) AS 총_소요시간_분,
        COUNT(DISTINCT CONCAT(location, '|', product_id)) AS 전체_작업_건수

    FROM performance_cte
    GROUP BY worker_id, 작업자이름
),

error_summary AS (

    SELECT
        worker_id,
        작업자이름,
        COUNT(DISTINCT CONCAT(location, '|', product_id)) AS 총_오류_건수

    FROM error_cte
    WHERE 판정_상세유형 != '정상(종료)'
    GROUP BY worker_id, 작업자이름
),

final_summary AS (

    SELECT
        P.worker_id,
        P.작업자이름,
        P.총_작업양,
        P.총_소요시간_분,

        ROUND(
            P.총_작업양 / NULLIF(P.총_소요시간_분 / 60.0, 0),
            2
        ) AS 전체_UPH,

        ROUND(
            P.총_소요시간_분 / NULLIF(P.총_작업양, 0),
            2
        ) AS 전체_HTP,

        COALESCE(E.총_오류_건수, 0) AS 총_오류_건수,

        ROUND(
            COALESCE(E.총_오류_건수, 0) * 100.0
            / NULLIF(P.전체_작업_건수, 0),
            2
        ) AS 오류율_퍼센트

    FROM performance_summary P
    LEFT JOIN error_summary E
        ON P.worker_id = E.worker_id
)

SELECT
    worker_id,
    작업자이름,
    총_작업양,
    총_소요시간_분,
    전체_UPH,
    전체_HTP,
    총_오류_건수,
    오류율_퍼센트,

    RANK() OVER (
        ORDER BY 오류율_퍼센트 DESC
    ) AS 오류율_순위,

    CASE
        WHEN 총_작업양 > AVG(총_작업양) OVER ()
        THEN '평균 이상'

        WHEN 총_작업양 < AVG(총_작업양) OVER ()
        THEN '평균 이하'

        ELSE '평균 동일'
    END AS 작업량_평가,

    ROUND(
        SUM(총_작업양) OVER (
            ORDER BY 총_작업양 DESC
        ) * 100.0
        / SUM(총_작업양) OVER (),
        2
    ) AS 누적_비중_퍼센트,

    CASE
        WHEN 전체_UPH >= AVG(전체_UPH) OVER ()
         AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER ()
        THEN '핵심성과형'

        WHEN 전체_UPH >= AVG(전체_UPH) OVER ()
         AND 오류율_퍼센트 > AVG(오류율_퍼센트) OVER ()
        THEN '품질리스크형'

        WHEN 전체_UPH < AVG(전체_UPH) OVER ()
         AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER ()
        THEN '안정운영형'

        ELSE '개선필요형'
    END AS 작업자_유형

FROM final_summary
ORDER BY 오류율_순위 ASC, 총_작업양 DESC;