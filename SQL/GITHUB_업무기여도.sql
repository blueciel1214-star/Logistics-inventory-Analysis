WITH performance_cte AS (

    -- CC 작업 성과 집계
    SELECT
        C.worker_id,
        COALESCE(W.name, C.worker_id) AS 작업자이름,
        C.location,
        C.product_id,
        C.product_name,

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
        S.product_name,

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

-- 오류 집계
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
             AND C.final_real_qty = S.system_qty
            THEN 'SBC오류'

            WHEN C.cc_status = '2차확정'
            THEN 'CC2차'

            WHEN C.cc_status = '3차확정'
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

-- 작업 성과 요약
performance_summary AS (

    SELECT
        worker_id,
        작업자이름,

        SUM(작업양) AS 총_작업양,

        COUNT(DISTINCT CONCAT(location, '|', product_id))
            AS 전체_작업_건수

    FROM performance_cte

    GROUP BY
        worker_id,
        작업자이름
),

-- 오류 요약
error_summary AS (

    SELECT
        worker_id,
        작업자이름,

        COUNT(DISTINCT CONCAT(location, '|', product_id))
            AS 총_오류_건수

    FROM error_cte

    WHERE 판정_상세유형 != '정상(종료)'

    GROUP BY
        worker_id,
        작업자이름
),

-- 최종 KPI
final_summary AS (

    SELECT
        P.worker_id,
        P.작업자이름,

        P.총_작업양,

        P.전체_작업_건수,

        COALESCE(E.총_오류_건수, 0)
            AS 총_오류_건수,

        ROUND(
            COALESCE(E.총_오류_건수, 0) * 100.0
            / NULLIF(P.전체_작업_건수, 0),
            2
        ) AS 오류율_퍼센트

    FROM performance_summary P

    LEFT JOIN error_summary E
        ON P.worker_id = E.worker_id
)

-- 운영 기여도 분석
SELECT
    worker_id,
    작업자이름,

    -- 총 작업량
    총_작업양,

    -- 평균 대비 작업량
    ROUND(
        총_작업양 - AVG(총_작업양) OVER (),
        2
    ) AS 평균대비_작업량,

    -- 오류율
    오류율_퍼센트,

    -- 누적 작업량
    SUM(총_작업양)
        OVER (ORDER BY 총_작업양 DESC)
        AS 누적_작업량,

    -- 누적 비중 %
    ROUND(
        SUM(총_작업양)
            OVER (ORDER BY 총_작업양 DESC)
        * 100.0
        / SUM(총_작업양) OVER (),
        2
    ) AS 누적비중_퍼센트,

    -- 운영 평가
    CASE

        WHEN 총_작업양 >= AVG(총_작업양) OVER ()
         AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER ()
        THEN '핵심 운영 인력'

        WHEN 총_작업양 >= AVG(총_작업양) OVER ()
         AND 오류율_퍼센트 > AVG(오류율_퍼센트) OVER ()
        THEN '과부하 위험'

        WHEN 총_작업양 < AVG(총_작업양) OVER ()
         AND 오류율_퍼센트 > AVG(오류율_퍼센트) OVER ()
        THEN '개선 필요'

        ELSE '일반 운영 인력'

    END AS 운영_평가

FROM final_summary

ORDER BY 총_작업양 DESC;