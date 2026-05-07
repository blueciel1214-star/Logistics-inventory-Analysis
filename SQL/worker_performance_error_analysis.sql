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
	--  재고조사 오류 집계
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
        C.product_name,

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

    -- SBC 작업자 이름 JOIN
    LEFT JOIN workers W_sbc
        ON S.worker_id = W_sbc.worker_id

    -- CC 작업자 이름 JOIN
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
        ) AS 전체_HTP_분,

        P.전체_작업_건수,

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
    전체_HTP_분,
    전체_작업_건수,
    총_오류_건수,
    오류율_퍼센트,

    -- 오류율 순위
    RANK() OVER (
        ORDER BY 오류율_퍼센트 DESC
    ) AS 오류율_순위,

    -- 누적 작업량
    SUM(총_작업양) OVER (
        ORDER BY 총_작업양 DESC
    ) AS 누적_작업량,

    -- 전체 평균 작업량
    ROUND(
        AVG(총_작업양) OVER (),
        2
    ) AS 전체_평균_작업량,

    -- 평균 대비 작업량 차이
    ROUND(
        총_작업양 - AVG(총_작업양) OVER (),
        2
    ) AS 평균대비_작업량_차이,

    -- 평균 대비 평가
    CASE
        WHEN 총_작업양 > AVG(총_작업양) OVER ()
        THEN '평균 이상'

        WHEN 총_작업양 < AVG(총_작업양) OVER ()
        THEN '평균 이하'

        ELSE '평균 동일'
    END AS 작업량_평가,

    -- 작업자 유형 분류
 CASE
    WHEN 전체_UPH >= AVG(전체_UPH) OVER ()
     AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER ()
     AND 총_작업양 >= AVG(총_작업양) OVER ()
    THEN '고성과자'

    WHEN 총_작업양 >= AVG(총_작업양) OVER ()
     AND 오류율_퍼센트 >= AVG(오류율_퍼센트) OVER ()
    THEN '과부하 또는 품질관리 필요'

    WHEN 총_작업양 < AVG(총_작업양) OVER ()
     AND 오류율_퍼센트 >= AVG(오류율_퍼센트) OVER ()
    THEN '교육 필요'

    ELSE '안정형'
END AS 작업자_유형

FROM final_summary

ORDER BY 오류율_순위 ASC, 총_작업양 DESC;