WITH cc_final AS (

    SELECT
        C.*
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

error_base AS (

    SELECT
        S.product_id,
        S.product_name,
        S.location,

        SUBSTRING_INDEX(
            TRIM(S.location),
            '-',
            -1
        ) AS 로케이션번호,

        CAST(
            LEFT(
                SUBSTRING_INDEX(
                    TRIM(S.location),
                    '-',
                    -1
                ),
                1
            ) AS SIGNED
        ) AS 단,

        CAST(
            RIGHT(
                SUBSTRING_INDEX(
                    TRIM(S.location),
                    '-',
                    -1
                ),
                2
            ) AS SIGNED
        ) AS 칸,

        S.system_qty AS 전산수량,
        S.real_qty AS SBC수량,
        C.final_real_qty AS 상품수량,
        C.최종차수

    FROM sbc_raw S

    JOIN cc_final C
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

        MAX(전산수량) AS 전산수량,
        MAX(SBC수량) AS SBC수량,
        MAX(상품수량) AS 상품수량,
        MAX(최종차수) AS 최종차수,

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

    /* 기준 로케이션 */
    A.location AS 기준_로케이션,
    A.로케이션번호 AS 기준_로케이션번호,

    /* 부족 = -, 초과 = + */
    A.상품수량 - A.전산수량 AS 기준_수량차이,

    /* 인접 로케이션 */
    B.location AS 인접_로케이션,
    B.로케이션번호 AS 인접_로케이션번호,

    /* 부족 = -, 초과 = + */
    B.상품수량 - B.전산수량 AS 인접_수량차이,

    /* 거리 차이 */
    ABS(A.단 - B.단) AS 단_차이,
    ABS(A.칸 - B.칸) AS 칸_차이,

    /* 패턴 분석 */
    CASE

        /* 완전 상쇄 */
        WHEN (A.상품수량 - A.전산수량)
           + (B.상품수량 - B.전산수량) = 0

         AND (A.상품수량 - A.전산수량) <> 0
         AND (B.상품수량 - B.전산수량) <> 0

        THEN '완전_교차의심'

        /* 방향 반대 */
        WHEN (A.상품수량 - A.전산수량)
           * (B.상품수량 - B.전산수량) < 0

        THEN '부분_교차의심'

        /* 동일 수량 */
        WHEN A.상품수량 = B.상품수량

        THEN '상품_단위_오류의심'

        ELSE '복합오류의심'

    END AS 패턴구분

FROM location_summary A

JOIN location_summary B
    ON A.product_id = B.product_id

   /* 자기 자신 제외 */
   AND A.location < B.location

   /* 동일 존 */
   AND SUBSTRING_INDEX(A.location, '-', 3)
       = SUBSTRING_INDEX(B.location, '-', 3)

   /* 인접 거리 */
   AND ABS(A.단 - B.단) <= 1
   AND ABS(A.칸 - B.칸) <= 2

ORDER BY
    SKU,
    기준_로케이션,
    인접_로케이션;