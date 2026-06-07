WITH cc_final AS (
    SELECT C.*
    FROM cc_raw C
    JOIN (
        SELECT 
            product_id, 
            location, 
            MAX(최종차수) AS max_최종차수
        FROM cc_raw
        GROUP BY 
            product_id, 
            location
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
    GROUP BY 
        product_id, 
        location
),

detailed_quality_raw AS (
    SELECT
        S.location,
        S.product_id,

        CASE
            WHEN S.qty_result = '불일치' 
             AND COALESCE(P.cc3_qty, P.cc2_qty, P.cc1_qty) = S.system_qty
            THEN S.worker_id

            WHEN C.cc_status = '2차확정' 
             AND P.cc2_qty <> P.cc1_qty 
             AND P.cc2_qty = S.real_qty
            THEN P.cc1_worker

            WHEN C.cc_status = '3차확정' 
             AND P.cc3_qty = P.cc2_qty 
             AND P.cc3_qty <> P.cc1_qty
            THEN P.cc1_worker

            WHEN C.cc_status = '3차확정' 
             AND P.cc3_qty = P.cc1_qty 
             AND P.cc3_qty <> P.cc2_qty
            THEN P.cc2_worker

            WHEN S.qty_result = '불일치' 
             AND C.cc_status IS NOT NULL 
            THEN C.worker_id

            ELSE S.worker_id
        END AS responsibility_worker_id,

        CASE
            WHEN S.qty_result = '정상' 
            THEN '정상(종료)'

            WHEN S.qty_result = '불일치' 
             AND C.cc_status = '1차확정' 
             AND C.final_real_qty = S.real_qty 
            THEN '정상(종료)'

            WHEN S.qty_result = '불일치' 
             AND COALESCE(P.cc3_qty, P.cc2_qty, P.cc1_qty) = S.system_qty 
            THEN 'SBC오류'

            WHEN (
                    C.cc_status = '2차확정' 
                AND P.cc2_qty <> P.cc1_qty 
                AND P.cc2_qty = S.real_qty
            )
            OR (
                    C.cc_status = '3차확정' 
                AND P.cc3_qty = P.cc2_qty 
                AND P.cc3_qty <> P.cc1_qty
            )
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

performance_cte AS (
    SELECT
        C.worker_id,
        COALESCE(W.name, C.worker_id) AS 작업자이름,

        C.final_real_qty AS 작업양,

        CASE 
            WHEN ABS(TIMESTAMPDIFF(MINUTE, C.`1차 작업시간`, C.`최종 작업시간`)) > 30 
            THEN 5 
            ELSE ABS(TIMESTAMPDIFF(MINUTE, C.`1차 작업시간`, C.`최종 작업시간`)) 
        END AS 소요시간_분

    FROM cc_raw C
    LEFT JOIN workers W 
        ON C.worker_id = W.worker_id

    UNION ALL

    SELECT
        S.worker_id,
        COALESCE(W.name, S.worker_id) AS 작업자이름,

        S.real_qty AS 작업양,

        CASE 
            WHEN ABS(TIMESTAMPDIFF(MINUTE, S.start_worktime, S.final_worktime)) > 30 
            THEN 5 
            ELSE ABS(TIMESTAMPDIFF(MINUTE, S.start_worktime, S.final_worktime)) 
        END AS 소요시간_분

    FROM sbc_raw S
    LEFT JOIN workers W 
        ON S.worker_id = W.worker_id
),

performance_summary AS (
    SELECT
        worker_id,
        작업자이름,

        SUM(작업양) AS 총_작업양,
        SUM(소요시간_분) AS 총_소요시간_분

    FROM performance_cte
    GROUP BY 
        worker_id, 
        작업자이름
),

sbc_work_summary AS (
    SELECT
        worker_id,
        COUNT(*) AS SBC_작업건수
    FROM sbc_raw
    GROUP BY 
        worker_id
),

error_summary AS (
    SELECT 
        responsibility_worker_id AS worker_id,
        COUNT(*) AS 오류_건수
    FROM detailed_quality_raw
    WHERE 판정_상세유형 IN (
        'SBC오류', 
        'CC1차_오류', 
        'CC2차_오류', 
        '다중_연쇄오류'
    )
    GROUP BY 
        responsibility_worker_id
),

final_summary AS (
    SELECT
        P.worker_id,
        P.작업자이름,

        P.총_작업양,
        P.총_소요시간_분,

        COALESCE(W.SBC_작업건수, 0) AS SBC_작업건수,
        COALESCE(E.오류_건수, 0) AS 오류_건수,

        ROUND(
            P.총_작업양 
            / NULLIF(P.총_소요시간_분 / 60.0, 0), 
            2
        ) AS 전체_UPH,

        ROUND(
            P.총_소요시간_분 
            / NULLIF(P.총_작업양, 0), 
            2
        ) AS 전체_HTP,

        ROUND(
            COALESCE(E.오류_건수, 0) * 100.0 
            / NULLIF(W.SBC_작업건수, 0), 
            2
        ) AS 오류율_퍼센트

    FROM performance_summary P

    LEFT JOIN sbc_work_summary W
        ON P.worker_id = W.worker_id

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

    SBC_작업건수,
    오류_건수,
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
        SUM(오류_건수) OVER (
            ORDER BY 오류_건수 DESC, worker_id ASC
        ) * 100.0
        / NULLIF(SUM(오류_건수) OVER (), 0),
        2
    ) AS 누적_오류_비율,

    CASE
        WHEN 전체_UPH >= AVG(전체_UPH) OVER () 
         AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER () 
        THEN '핵심성과형'

        WHEN 전체_UPH >= AVG(전체_UPH) OVER () 
         AND 오류율_퍼센트 > AVG(오류율_퍼센트) OVER () 
        THEN '품질리스크형'

        WHEN 전체_UPH < AVG(전체_UPH) OVER () 
         AND 오류율_퍼센트 <= AVG(오류율_퍼센트) OVER () 
        THEN '안정작업형'

        ELSE '개선필요형'
    END AS 작업자_유형

FROM final_summary

ORDER BY 
    오류_건수 DESC,
    worker_id ASC;