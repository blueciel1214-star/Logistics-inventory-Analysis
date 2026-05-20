WITH location_base AS (
    SELECT
        S.location AS 로케이션,

        SUBSTRING(SUBSTRING_INDEX(S.location, '-', -1), 1, 1) AS 재고_층,
        SUBSTRING(SUBSTRING_INDEX(S.location, '-', -1), 2, 2) AS 칸_순서,

        COUNT(*) AS 전체작업건수,

        SUM(CASE
            WHEN S.qty_result = '불일치'
            THEN 1 ELSE 0
        END) AS 불일치_발생건수

    FROM sbc_raw S

    GROUP BY
        S.location,
        SUBSTRING(SUBSTRING_INDEX(S.location, '-', -1), 1, 1),
        SUBSTRING(SUBSTRING_INDEX(S.location, '-', -1), 2, 2)
)

SELECT
    재고_층,
    칸_순서,
    SUM(전체작업건수) AS 전체작업건수,
    SUM(불일치_발생건수) AS 불일치_발생건수,

    ROUND(
        SUM(불일치_발생건수) * 100.0
        / NULLIF(SUM(전체작업건수), 0),
        2
    ) AS 불일치율_퍼센트,

    ROUND(
        SUM(불일치_발생건수) * 100.0
        / NULLIF(SUM(SUM(불일치_발생건수)) OVER(), 0),
        2
    ) AS 구성비율_퍼센트

FROM location_base

GROUP BY
    재고_층,
    칸_순서

HAVING
    SUM(불일치_발생건수) > 0

ORDER BY
    재고_층 DESC,
    칸_순서 DESC;