WITH CTE AS (
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

        S.location AS 로케이션,
        S.product_id,
        S.product_name AS 상품명,
        S.category AS 카테고리,

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

    FROM sbc_raw S

    LEFT JOIN cc_raw C
        ON S.location = C.location
       AND S.product_id = C.product_id

    LEFT JOIN workers W_sbc
        ON S.worker_id = W_sbc.worker_id

    LEFT JOIN workers W_cc
        ON C.worker_id = W_cc.worker_id
),

Work_Summary AS (
    SELECT
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 1, 1) AS 재고_층,
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 2, 2) AS 칸_순서,
        COUNT(*) AS 전체작업건수
    FROM CTE
    GROUP BY
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 1, 1),
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 2, 2)
),

Error_Summary AS (
    SELECT
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 1, 1) AS 재고_층,
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 2, 2) AS 칸_순서,
        COUNT(*) AS 오류_발생건수
    FROM CTE
    WHERE 판정_상세유형 IN ('SBC오류', 'CC2차', 'CC3차')
    GROUP BY
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 1, 1),
        SUBSTRING(SUBSTRING_INDEX(로케이션, '-', -1), 2, 2)
)

SELECT 
    W.재고_층,
    W.칸_순서,
    W.전체작업건수,

    COALESCE(E.오류_발생건수, 0) AS 오류_발생건수,

    ROUND(
        COALESCE(E.오류_발생건수, 0) * 100.0
        / NULLIF(W.전체작업건수, 0),
        2
    ) AS 오류율_퍼센트,

    ROUND(
        COALESCE(E.오류_발생건수, 0) * 100.0
        / NULLIF(SUM(COALESCE(E.오류_발생건수, 0)) OVER(), 0),
        2
    ) AS 구성비율_퍼센트

FROM Work_Summary W

LEFT JOIN Error_Summary E
    ON W.재고_층 = E.재고_층
   AND W.칸_순서 = E.칸_순서

ORDER BY 
    W.재고_층,
    W.칸_순서;