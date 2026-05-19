WITH error_base AS (

    SELECT
        S.product_id,
        S.product_name,
        S.location,

        SUBSTRING_INDEX(TRIM(S.location), '-', -1) AS 로케이션번호,
        CAST(LEFT(SUBSTRING_INDEX(TRIM(S.location), '-', -1), 1) AS SIGNED) AS 단,
        CAST(RIGHT(SUBSTRING_INDEX(TRIM(S.location), '-', -1), 2) AS SIGNED) AS 칸,

        S.real_qty - C.final_real_qty AS 수량차이

    FROM sbc_raw S
    JOIN cc_raw C
        ON S.location = C.location
       AND S.product_id = C.product_id

    WHERE S.qty_result = '불일치'
),

location_summary AS (

    SELECT
        product_id,
        product_name,
        location,
        로케이션번호,
        단,
        칸,
        SUM(수량차이) AS 총_수량차이,
        COUNT(*) AS 오류건수

    FROM error_base

    GROUP BY
        product_id,
        product_name,
        location,
        로케이션번호,
        단,
        칸
)

SELECT
    A.product_id AS SKU,
    A.product_name AS 상품명,

    A.location AS 기준_로케이션,
    A.로케이션번호 AS 기준_로케이션번호,

    B.location AS 인접_로케이션,
    B.로케이션번호 AS 인접_로케이션번호,

    ABS(A.단 - B.단) AS 단_차이,
    ABS(A.칸 - B.칸) AS 칸_차이,

    '인접오류후보' AS 패턴구분

FROM location_summary A

JOIN location_summary B
    ON A.product_id = B.product_id
   AND A.location < B.location
   AND SUBSTRING_INDEX(A.location, '-', 3)
       = SUBSTRING_INDEX(B.location, '-', 3)
   AND ABS(A.단 - B.단) <= 1
   AND ABS(A.칸 - B.칸) <= 2

ORDER BY
    SKU,
    기준_로케이션,
    인접_로케이션;