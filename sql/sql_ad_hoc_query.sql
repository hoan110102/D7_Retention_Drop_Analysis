use core;

/* ============================================================
   XÁC NHẬN VẤN ĐỀ
   D7 retention theo từng ngày cohort – xác nhận trend thực sự giảm
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date < '2026-03-15 00:00:00'
),
last_active AS (
    SELECT
        account_id,
        MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions
    GROUP BY 1
)
SELECT
    a.first_login_day AS cohort_date,
    COUNT(DISTINCT a.account_id) AS cohort_size,
    COUNT(DISTINCT
    		CASE
	        WHEN DATE_DIFF('day', a.first_login_day, la.last_active_day) >= 7
	        THEN a.account_id
	    END) AS retained_d7,
    ROUND(
        COUNT(DISTINCT 
        		CASE
	            WHEN DATE_DIFF('day', a.first_login_day, la.last_active_day) >= 7
	            THEN a.account_id
            END)
        *100/COUNT(DISTINCT a.account_id)
    , 2) AS d7_retention_pct
FROM acc_base a
LEFT JOIN last_active la
	ON la.account_id=a.account_id
-- chỉ tính cohort đã có đủ 7 ngày kể từ first_login đến 14/3
WHERE a.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
GROUP BY 1
ORDER BY 1;


/* ============================================================
   Q1 – NHÁNH A: VẤN ĐỀ KỸ THUẬT
   Crash rate theo cohort và device_tier
   => Nếu crash rate tương đương giữa các nhóm → loại trừ nhánh A
   ============================================================ */

WITH acc_base AS (
    SELECT
        a.account_id,
        a.first_login_date::DATE AS first_login_day,
        -- lấy device_tier qua user_id trong session → dim_users
        -- (1 account có thể dùng nhiều device, lấy tier xuất hiện nhiều nhất)
        NULL AS placeholder   -- join với dim_users qua session bên dưới
    FROM dim_accounts a
    WHERE a.first_login_date >= '2026-03-01 00:00:00'
    		AND a.first_login_date < '2026-03-08 00:00:00'
),
session_with_tier AS (
    SELECT
        s.session_id,
        s.account_id,
        s.session_start_ts::DATE AS session_date,
        s.crash_count,
        s.end_reason,
        du.device_tier,
        ROW_NUMBER() OVER (
            PARTITION BY s.account_id
            ORDER BY s.session_start_ts
        ) AS rn
    FROM fact_user_sessions s
    -- join device_tier qua user_id trong session
    JOIN dim_users du 
    		ON du.user_id = s.user_id
),
-- gộp DAY_CHANGE: session hệ thống tạo ra không đếm riêng
session_lag AS (
    SELECT
        s.session_id,
        s.account_id,
        s.session_start_ts,
        s.session_end_ts,
        s.session_duration_sec,
        s.end_reason,
        s.crash_count,
        du.device_tier,
        LAG(s.end_reason) OVER (PARTITION BY s.account_id ORDER BY s.session_start_ts) AS prev_end_reason,
        LAG(s.session_end_ts) OVER (PARTITION BY s.account_id ORDER BY s.session_start_ts) AS prev_end_ts
    FROM fact_user_sessions s
    JOIN dim_users du 
    		ON du.user_id = s.user_id
),
clean_sessions AS (
    SELECT *
    FROM session_lag
    -- loại session "hệ thống tạo": prev là DAY_CHANGE và gap < 5 giây
    WHERE NOT (
        prev_end_reason = 'DAY_CHANGE'
        AND EPOCH(session_start_ts) - EPOCH(prev_end_ts) < 5
    )
),
cohort_sessions AS (
    SELECT
        cs.session_id,
        cs.account_id,
        cs.crash_count,
        cs.device_tier
    FROM clean_sessions cs
    JOIN dim_accounts da
    		ON da.account_id=cs.account_id
)
SELECT
    da.first_login_date::DATE AS cohort_date,
    cs.device_tier,
    COUNT(cs.session_id) AS total_sessions,
    ROUND(AVG(cs.crash_count), 4) AS avg_crash_per_session,
    ROUND(
        SUM(CASE WHEN cs.crash_count > 0 THEN 1 ELSE 0 END)
        *100/COUNT(cs.session_id)
    , 2) AS crash_session_rate_pct
FROM cohort_sessions cs
JOIN dim_accounts da
	ON cs.account_id=da.account_id
GROUP BY 1, 2
ORDER BY 1, 2;


/* ============================================================
   Q2 – NHÁNH B: VẤN ĐỀ ACQUISITION
   D1 / D3 / D7 retention theo channel và campaign
   => Nếu D1/D3 bình thường và chỉ D7 giảm → không phải UA
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
-- lấy channel/campaign từ dim_users qua user_id trong session đầu tiên của account
first_user AS (
    SELECT
        s.account_id,
        s.user_id,
        ROW_NUMBER() OVER (
        		PARTITION BY s.account_id 
        		ORDER BY s.session_start_ts
        	) AS rn
    FROM fact_user_sessions s
),
acc_channel AS (
    SELECT
        fu.account_id,
        du.channel,
        du.campaign_id
    FROM first_user fu
    JOIN dim_users du 
    		ON du.user_id = fu.user_id
    WHERE fu.rn = 1
),
last_active AS (
    SELECT
        account_id,
        MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions
    GROUP BY account_id
),
joined AS (
    SELECT
        ab.account_id,
        ab.first_login_day,
        ac.channel,
        ac.campaign_id,
        DATE_DIFF('day', ab.first_login_day,
                  COALESCE(la.last_active_day, ab.first_login_day)
        ) AS active_days
    FROM acc_base ab
    LEFT JOIN acc_channel ac
    		ON ac.account_id=ab.account_id
    LEFT JOIN last_active la
    		ON la.account_id=ab.account_id
)
SELECT
    channel,
    campaign_id,
    COUNT(*) AS cohort_size,
    ROUND(AVG((active_days >= 1)::INT) * 100, 1) AS d1_pct,
    -- D3 chỉ tính account đã đủ 3 ngày trong window
    ROUND(AVG(CASE
        WHEN DATE_DIFF('day', first_login_day, DATE '2026-03-14') >= 3
        THEN (active_days >= 3)::INT END) * 100, 1) AS d3_pct,
    ROUND(AVG(CASE
        WHEN DATE_DIFF('day', first_login_day, DATE '2026-03-14') >= 7
        THEN (active_days >= 7)::INT END) * 100, 1) AS d7_pct
FROM joined
GROUP BY 1, 2
ORDER BY 3 DESC;


/* ============================================================
   Q3.1 – NHÁNH C: VẤN ĐỀ GAMEPLAY
   Phân phối ngày cuối cùng active (last_active_dayidx) của churned accounts
   => Xác định người chơi drop vào ngày mấy trong vòng đời
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT
        account_id,
        MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions
    GROUP BY 1
),
churned AS (
    SELECT
        ab.account_id,
        ab.first_login_day,
        DATE_DIFF('day', ab.first_login_day, la.last_active_day) AS last_active_dayidx
    FROM acc_base ab
    JOIN last_active la USING (account_id)
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS  -- churn trước D7
)
SELECT
	first_login_day,
    last_active_dayidx,
    COUNT(*) AS churned_accounts,
    ROUND(COUNT(*) *100/SUM(COUNT(*)) OVER (partition by first_login_day), 1) AS pct_of_churned
FROM churned
GROUP BY 1, 2
ORDER BY 1, 2;


/* ============================================================
   Q3.2 – NHÁNH C: VẤN ĐỀ GAMEPLAY
   Avg sessions/ngày theo day_idx, chỉ nhóm churn trước D7
   => Xem session count thay đổi như thế nào trước khi drop
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
churned_accs AS (
    SELECT ab.account_id, ab.first_login_day
    FROM acc_base ab
    JOIN last_active la USING (account_id)
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS
),
-- clean_sessions: loại DAY_CHANGE hệ thống tạo
session_lag AS (
    SELECT
        account_id,
        session_start_ts,
        end_reason,
        LAG(end_reason) OVER (PARTITION BY account_id ORDER BY session_start_ts) AS prev_end_reason,
        LAG(session_end_ts) OVER (PARTITION BY account_id ORDER BY session_start_ts) AS prev_end_ts
    FROM fact_user_sessions
),
clean_sessions AS (
    SELECT 
    		account_id, 
    		session_start_ts::DATE as session_start_date
    FROM session_lag
    WHERE NOT (
        prev_end_reason = 'DAY_CHANGE'
        AND EPOCH(session_start_ts) - EPOCH(prev_end_ts) < 5
    )
),
daily_sessions AS (
    SELECT
        ca.account_id,
        DATE_DIFF('day', ca.first_login_day, cs.session_start_date) AS day_idx,
        COUNT(*) AS sessions_that_day
    FROM clean_sessions cs
    JOIN churned_accs ca
    		ON cs.account_id=ca.account_id
    WHERE cs.session_start_date <= ca.first_login_day + INTERVAL 6 DAYS
    		AND cs.session_start_date >= ca.first_login_day
    GROUP BY 1, 2
)
SELECT
    day_idx,
    COUNT(DISTINCT account_id) AS active_accounts,
    ROUND(AVG(sessions_that_day), 2) AS avg_sessions_per_user
FROM daily_sessions
GROUP BY 1
ORDER BY 1;


/* ============================================================
   Q4.1 – HỌ ĐANG LÀM GÌ TRƯỚC KHI DROP
   Chapter cuối mà người chơi attempt trước khi drop
   => Tìm điểm kẹt
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
churned_accs AS (
    SELECT 
    		ab.account_id, 
    		ab.first_login_day, 
    		la.last_active_day
    FROM acc_base ab
    JOIN last_active la
    		ON ab.account_id=la.account_id
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS
),
-- lấy tất cả attempt của churned accounts trước ngày drop
attempts_before_drop AS (
    SELECT
        fa.account_id,
        fa.chapter_id,
        fa.level_id,
        fa.attempt_result,
        ROW_NUMBER() OVER (PARTITION BY fa.account_id ORDER BY fa.attempt_ts DESC) as rn
    FROM fact_stage_attempts fa
    JOIN churned_accs ca
    		ON fa.account_id=ca.account_id
    WHERE fa.attempt_ts::DATE <= ca.last_active_day
)
-- tìm chapter có số người drop cao nhất
select
	chapter_id,
	count(distinct case when rn=1 then account_id end) as drop_user_count
from attempts_before_drop
group by 1
order by 2 desc;


/* ============================================================
   Q4.2 – WIN RATE TẠI ĐIỂM KẸT
   Tính win rate theo 2 góc: per-user và per-attempt
   (thay chapter_id/level_id bằng kết quả tìm được ở Q4.1) => kết quả là chapter 6
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
churned_accs AS (
    SELECT 
    		ab.account_id, 
    		ab.first_login_day, 
    		la.last_active_day
    FROM acc_base ab
    JOIN last_active la
		on la.account_id=ab.account_id
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS
),
all_attempts AS (
    SELECT 
        fa.account_id,
        fa.chapter_id,
        fa.level_id,
        fa.attempt_result,
        -- Đánh dấu lượt chơi cuối cùng trong đời của user
        ROW_NUMBER() OVER(PARTITION BY fa.account_id ORDER BY fa.attempt_ts DESC) as rn
    FROM fact_stage_attempts fa
    JOIN churned_accs ca
		ON ca.account_id=fa.account_id
    WHERE fa.attempt_ts::DATE <= ca.last_active_day
),
user_drop_points AS (
    -- Tìm chính xác màn chơi cuối cùng mà user thực hiện trước khi drop
    SELECT 
        account_id,
        chapter_id,
        level_id,
        -- Nếu trận cuối cùng trong đời là WIN, nghĩa là họ vượt qua màn rồi mới drop
        -- Nếu là FAIL/QUIT, nghĩa là họ bị kẹt chết tại màn này không qua nổi
        CASE WHEN attempt_result = 'WIN' THEN 1 ELSE 0 END as is_win_before_drop
    FROM all_attempts
    WHERE rn = 1
),
level_aggregate AS (
    -- Tính toán tổng số attempt và trận thắng tổng quan của từng Level
    SELECT 
        chapter_id,
        level_id,
        COUNT(*) as total_attempts,
        COUNT(CASE WHEN attempt_result = 'WIN' THEN 1 END) as total_wins
    FROM all_attempts
    GROUP BY 1, 2
)
SELECT
    la.level_id,
    -- Số user thực sự drop tại chính level này
    COUNT(DISTINCT udp.account_id) as actual_drop_user_count,
    -- Attempt Winrate (Tổng trận thắng / Tổng trận chơi tại level này)
    la.total_wins * 100.0 / NULLIF(la.total_attempts, 0) as attempt_winrate,
    -- User Winrate tại điểm chết
    -- Thể hiện: Trong số những người drop tại màn này, có bao nhiêu % là đã WIN được màn này rồi mới bỏ?
    SUM(udp.is_win_before_drop)*100/NULLIF(COUNT(DISTINCT udp.account_id), 0) as user_winrate_at_drop_point
FROM level_aggregate la
LEFT JOIN user_drop_points udp 
	ON la.chapter_id = udp.chapter_id 
	AND la.level_id = udp.level_id
WHERE la.chapter_id=6
GROUP BY 1, la.total_wins, la.total_attempts
ORDER BY 1, 2;


/* ============================================================
   Q4.3 – ATTEMPT COUNT TẠI ĐIỂM KẸT
   Phân phối số lần attempt tại level kẹt của churned accounts
   => Xác nhận họ thật sự thử nhiều lần trước khi drop
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
churned_accs AS (
    SELECT 
    		ab.account_id, 
    		ab.first_login_day, 
    		la.last_active_day
    FROM acc_base ab
    JOIN last_active la 
		ON la.account_id=ab.account_id
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS
),
all_attempts AS (
    SELECT 
        fa.account_id,
        fa.chapter_id,
        fa.level_id,
        -- Định vị hành động cuối cùng trong đời của user
        ROW_NUMBER() OVER(PARTITION BY fa.account_id ORDER BY fa.attempt_ts DESC) as rn
    FROM fact_stage_attempts fa
    JOIN churned_accs ca USING (account_id)
    WHERE fa.attempt_ts::DATE <= ca.last_active_day
    		AND fa.chapter_id=6
),
user_final_gate AS (
    SELECT 
        account_id,
        chapter_id,
        level_id
    FROM all_attempts
    WHERE rn = 1
),
gate_attempts_count AS (
    -- Đếm tổng số lần attempts của user tại đúng cái Level cuối cùng đó
    SELECT 
        f.chapter_id,
        f.level_id,
        f.account_id,
        COUNT(a.attempt_id) AS total_attempts_at_gate
    FROM user_final_gate f
    JOIN fact_stage_attempts a 
		ON f.account_id = a.account_id 
		AND f.chapter_id = a.chapter_id 
		AND f.level_id = a.level_id
    GROUP BY 1, 2, 3
),
binning_users AS (
    -- Phân loại số lần attempt vào các bin
    SELECT 
        chapter_id,
        level_id,
        account_id,
        CASE 
            WHEN total_attempts_at_gate = 1 THEN '1'
            WHEN total_attempts_at_gate BETWEEN 2 AND 3 THEN '2-3'
            WHEN total_attempts_at_gate BETWEEN 4 AND 5 THEN '4-5'
            WHEN total_attempts_at_gate BETWEEN 6 AND 9 THEN '6-9'
            ELSE '10+' 
        END AS attempt_bin
    FROM gate_attempts_count
)
SELECT 
    chapter_id,
    level_id,
    COUNT(DISTINCT account_id) AS total_drop_users,
    COUNT(DISTINCT CASE WHEN attempt_bin = '1' THEN account_id END) AS '1_attempt',
    COUNT(DISTINCT CASE WHEN attempt_bin = '2-3' THEN account_id END) AS '2_3_attempts',
    COUNT(DISTINCT CASE WHEN attempt_bin = '4-5' THEN account_id END) AS '4_5_attempts',
    COUNT(DISTINCT CASE WHEN attempt_bin = '6-9' THEN account_id END) AS '6_9_attempts',
    COUNT(DISTINCT CASE WHEN attempt_bin = '10+' THEN account_id END) AS '10+_attempts'
FROM binning_users
GROUP BY 1, 2
ORDER BY 1, 2;


/* ============================================================
   Q5.1 – KIỂM TRA CHÉO
   D7 retention payer vs F2P trong cohort điều tra
   => Nếu payer không bị ảnh hưởng → vấn đề chỉ ở F2P
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day,
        is_paying_user_flag
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
)
SELECT
    CASE 
	    WHEN ab.is_paying_user_flag THEN 'payer' 
	    ELSE 'f2p' 
	END AS user_type,
    COUNT(*) AS total_accounts,
    SUM((DATE_DIFF('day', ab.first_login_day,
                   COALESCE(la.last_active_day, ab.first_login_day)) >= 7)::INT) AS retained_d7,
    ROUND(AVG(
        (DATE_DIFF('day', ab.first_login_day,
                   COALESCE(la.last_active_day, ab.first_login_day)) >= 7)::INT
    ) * 100, 1) AS d7_retention_pct
FROM acc_base ab
LEFT JOIN last_active la 
	ON ab.account_id=la.account_id
GROUP BY 1
ORDER BY 1;


/* ============================================================
   Q5.2 – KIỂM TRA CHÉO
   Avg revive count tại level kẹt: payer vs F2P
   => F2P revive nhiều hơn nhưng vẫn không qua → power/difficulty issue
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day,
        is_paying_user_flag
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
churned_accs AS (
    SELECT 
    		ab.account_id, 
    		ab.is_paying_user_flag
    FROM acc_base ab
    JOIN last_active la 
		ON ab.account_id=la.account_id
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
      AND la.last_active_day < ab.first_login_day + INTERVAL 7 DAYS
)
SELECT
    CASE WHEN ca.is_paying_user_flag THEN 'payer' ELSE 'f2p' END AS user_type,
    COUNT(DISTINCT fa.account_id) AS accounts,
    COUNT(fa.attempt_id) AS total_attempts,
    ROUND(AVG(fa.revive_count), 2) AS avg_revive_per_attempt,
    ROUND(SUM(fa.revive_count) * 1.0
          / NULLIF(COUNT(DISTINCT fa.account_id), 0), 2) AS total_revive_per_user,
    -- % attempt có ít nhất 1 revive
    ROUND(AVG((fa.revive_count > 0)::INT) * 100, 1) AS attempts_with_revive_pct
FROM fact_stage_attempts fa
JOIN churned_accs ca USING (account_id)
-- *** thay giá trị chapter_id theo kết quả Q4.1 ***
WHERE fa.chapter_id = 6
GROUP BY 1
ORDER BY 1;


/* ============================================================
   Q5.3 – KIỂM TRA CHÉO
   Retained D7 vs Churned: so sánh avg session count và duration
   => Nếu tương đương → vấn đề là độ khó, không phải do lười cày
   => Nếu retained có session cao hơn → người cày nhiều thì vượt được
   ============================================================ */

WITH acc_base AS (
    SELECT
        account_id,
        first_login_date::DATE AS first_login_day
    FROM dim_accounts
    WHERE first_login_date >= '2026-03-01 00:00:00'
    		AND first_login_date < '2026-03-08 00:00:00'
		AND is_paying_user_flag = FALSE    -- chỉ F2P để loại biến nhiễu payer
),
last_active AS (
    SELECT 
    		account_id, 
    		MAX(session_start_ts::DATE) AS last_active_day
    FROM fact_user_sessions 
    GROUP BY 1
),
labelled AS (
    SELECT
        ab.account_id,
        ab.first_login_day,
        CASE
            WHEN DATE_DIFF('day', ab.first_login_day,
                           COALESCE(la.last_active_day, ab.first_login_day)) >= 7
            THEN 'retained'
            ELSE 'churned'
        END AS outcome
    FROM acc_base ab
    LEFT JOIN last_active la USING (account_id)
    WHERE ab.first_login_day <= DATE '2026-03-14' - INTERVAL 7 DAYS
),
-- clean_sessions: loại DAY_CHANGE hệ thống tạo, cộng duration vào session gốc
session_lag AS (
    SELECT
        s.account_id,
        s.session_id,
        s.session_start_ts,
        s.session_end_ts,
        s.session_duration_sec,
        s.end_reason,
        LAG(s.end_reason) OVER (PARTITION BY s.account_id ORDER BY s.session_start_ts) AS prev_end_reason,
        LAG(s.session_end_ts) OVER (PARTITION BY s.account_id ORDER BY s.session_start_ts) AS prev_end_ts,
        LEAD(s.session_duration_sec) OVER (PARTITION BY s.account_id ORDER BY s.session_start_ts) AS next_duration
    FROM fact_user_sessions s
),
clean_sessions AS (
    SELECT
        account_id,
        session_id,
        session_start_ts::DATE AS session_start_date,
        session_end_ts::DATE AS session_end_date,
        end_reason,
        -- cộng duration của session giả (ngày hôm sau) vào session gốc DAY_CHANGE
        CASE
            WHEN end_reason = 'DAY_CHANGE'
                 AND LEAD(session_start_ts) OVER (PARTITION BY account_id ORDER BY session_start_ts) IS NOT NULL
                 AND EPOCH(LEAD(session_start_ts) OVER (PARTITION BY account_id ORDER BY session_start_ts))
                     - EPOCH(session_end_ts) < 5
            THEN session_duration_sec + COALESCE(next_duration, 0)
            ELSE session_duration_sec
        END AS adj_duration_sec,
        prev_end_reason,
        prev_end_ts
    FROM session_lag
    -- loại session giả
    WHERE NOT (
        prev_end_reason = 'DAY_CHANGE'
        AND EPOCH(session_start_ts) - EPOCH(prev_end_ts) < 5
    )
),
-- chỉ lấy session trong 6 ngày đầu (D0–D5) của mỗi account
daily_metrics AS (
    SELECT
        lb.outcome,
        lb.account_id,
        DATE_DIFF('day', lb.first_login_day, cs.session_start_date) AS day_idx,
        COUNT(cs.session_id) AS sessions_per_day,
        SUM(cs.adj_duration_sec) AS total_duration_sec
    FROM clean_sessions cs
    JOIN labelled lb 
		ON lb.account_id=cs.account_id
	WHERE cs.session_start_date <= lb.first_login_day + INTERVAL 6 DAYS
    		AND cs.session_start_date >= lb.first_login_day
    GROUP BY 1, 2, 3
)
SELECT
    outcome,
    day_idx,
    COUNT(DISTINCT account_id) AS active_accounts,
    ROUND(AVG(sessions_per_day), 2) AS avg_sessions_per_day,
    ROUND(AVG(total_duration_sec) / 60, 1) AS avg_total_playtime_min
FROM daily_metrics
GROUP BY 1, 2
ORDER BY 1, 2;