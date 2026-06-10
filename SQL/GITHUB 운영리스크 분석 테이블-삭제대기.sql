WITH performance_cte AS (

    -- SBC 작업 성과
    SELECT
        S.worker_id,
        S.real_qty AS 작업양,
        TIMESTAMPDIFF(
            MINUTE,
            S.start_worktime,
            S.final_worktime
        ) AS 소요시간_분
    FROM sbc_raw S

    UNION ALL

    -- CC 작업 성과
    SELECT
        C.worker_id,
        C.final_real_qty AS 작업양,
        TIMESTAMPDIFF(
            MINUTE,
            C.`1차 작업시간`,
            C.`최종 작업시간`
        ) AS 소요시간_분
    FROM cc_raw C
),

worker_kpi AS (
    SELECT
        P.worker_id,
        COALESCE(W.name, P.worker_id) AS 작업자이름,

        SUM(P.작업양) AS 총_작업양,
        SUM(P.소요시간_분) AS 총_소요시간_분,

        ROUND(
            SUM(P.작업양) / NULLIF(SUM(P.소요시간_분) / 60.0, 0),
            2
        ) AS 상품수량기준_UPH,

        ROUND(
            SUM(P.소요시간_분) / NULLIF(SUM(P.작업양), 0),
            2
        ) AS 상품수량기준_HTP_분,

        COUNT(*) AS 전체_작업_건수

    FROM performance_cte P
    LEFT JOIN workers W
        ON P.worker_id = W.worker_id

    GROUP BY
        P.worker_id,
        W.name
),

recheck_summary AS (
    SELECT
        S.worker_id,

        SUM(
            CASE
                WHEN S.qty_result = '불일치'
                THEN COALESCE(C.최종차수, 0)
                ELSE 0
            END
        ) AS 총_재검수_유발건수,

        ROUND(
            SUM(
                CASE
                    WHEN S.qty_result = '불일치'
                    THEN COALESCE(C.최종차수, 0)
                    ELSE 0
                END
            ) * 100.0 / NULLIF(COUNT(S.plan_no), 0),
            2
        ) AS 재검수율_퍼센트

    FROM sbc_raw S
    LEFT JOIN cc_raw C
        ON S.location = C.location
       AND S.product_id = C.product_id

    GROUP BY
        S.worker_id
),

final_kpi AS (
    SELECT
        K.worker_id,
        K.작업자이름,
        K.총_작업양,
        K.총_소요시간_분,
        K.상품수량기준_UPH,
        K.상품수량기준_HTP_분,
        K.전체_작업_건수,

        COALESCE(R.총_재검수_유발건수, 0) AS 총_재검수_유발건수,
        COALESCE(R.재검수율_퍼센트, 0) AS 재검수율_퍼센트,

        ROUND(
            COALESCE(R.총_재검수_유발건수, 0) * K.상품수량기준_HTP_분,
            2
        ) AS 운영부하시간,

        ROUND(
            K.총_작업양 * 100.0 / NULLIF(SUM(K.총_작업양) OVER (), 0),
            2
        ) AS 작업량_비중_퍼센트

    FROM worker_kpi K
    LEFT JOIN recheck_summary R
        ON K.worker_id = R.worker_id
)

SELECT
    worker_id,
    작업자이름,
    총_작업양,
    총_소요시간_분,
    상품수량기준_UPH,
   상품수량기준_HTP_분,
    전체_작업_건수,
    총_재검수_유발건수,
    재검수율_퍼센트,
   운영부하시간,
    작업량_비중_퍼센트,

    RANK() OVER (
        ORDER BY
            운영부하시간 DESC,
            총_재검수_유발건수 DESC,
            재검수율_퍼센트 DESC
    ) AS 운영리스크_순위,

    CASE
        WHEN 상품수량기준_UPH >= AVG(상품수량기준_UPH) OVER ()
         AND 재검수율_퍼센트 <= AVG(재검수율_퍼센트) OVER ()
        THEN '핵심성과형'

        WHEN 상품수량기준_UPH >= AVG(상품수량기준_UPH) OVER ()
         AND 재검수율_퍼센트 > AVG(재검수율_퍼센트) OVER ()
        THEN '품질리스크형'

        WHEN 상품수량기준_UPH
        < AVG(상품수량기준_UPH) OVER ()
         AND 재검수율_퍼센트 <= AVG(재검수율_퍼센트) OVER ()
        THEN '안정작업형'

        ELSE '개선필요형'
    END AS 운영리스크_유형,
    
-- 운영관리대상
CASE
    WHEN RANK() OVER (
        ORDER BY
            운영부하시간 DESC,
            총_재검수_유발건수 DESC,
            재검수율_퍼센트 DESC
    ) <= 3
    THEN '1순위 관리대상'

    WHEN 재검수율_퍼센트 >= 10
    THEN '집중관리'

    WHEN 재검수율_퍼센트 >= 5
    THEN '관찰대상'

    ELSE '정상관리'
END AS 운영_관리대상
FROM final_kpi

ORDER BY
    운영리스크_순위 ASC;
