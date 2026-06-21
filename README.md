# Dự Án Phân Tích Nguyên Nhân Sụt Giảm Tỷ Lệ Duy Trì Ngày 7 (D7 Retention Drop Analysis)

## 📌 Tổng Quan Dự Án

Đây là một dự án **phân tích dữ liệu ad-hoc** nhằm điều tra và tìm ra nguyên nhân cốt lõi dẫn đến sự sụt giảm nghiêm trọng về tỷ lệ duy trì Ngày 7 (**D7 Retention**) của người chơi trong các cohort từ ngày 01/03/2026 đến 07/03/2026 (giảm mạnh từ **53.96%** xuống chỉ còn **16.28%**).

Dự án tập trung bóc tách dữ liệu hành vi, phân khúc người chơi (F2P vs Payer), tỷ lệ crash ứng dụng và thiết kế màn chơi để đưa ra các giải pháp khắc phục cụ thể cho đội ngũ vận hành và phát triển game.

---

## 📂 Cấu Trúc Khối Lượng Công Việc (Repository Structure)

```text
d7_retention_drop_analysis/
│
├── chart_visualized/                       # Lưu trữ các biểu đồ phân tích
├── sql/
│   └── sql_ad_hoc_query.sql               # Tổng hợp toàn bộ mã nguồn SQL truy vấn dữ liệu từ DB
├── notebooks/
│   └── visualize.ipynb                    # Jupyter Notebook kết nối DuckDB, xử lý dữ liệu và vẽ biểu đồ
├── reports/
│   └── D7_Retention_Drop_Analysis_Report.pdf # File báo cáo phân tích chi tiết và khuyến nghị cuối cùng
└── README.md                              # Tài liệu hướng dẫn và giới thiệu tổng quan dự án

```

---

## 🔍 Kết Quả Phân Tích Chính (Key Insights)

Qua quá trình truy vấn dữ liệu từ hệ thống DB và trực quan hóa hành vi người chơi, dự án đã xác định được các nguyên nhân chính sau:

* **Điểm nghẽn độ khó (Game Difficulty Bottleneck):** Phát hiện một lượng lớn người chơi rời bỏ game tại **Chapter 6**. Tại đây, tỷ lệ thắng (Win Rate) giảm sâu xuống còn **~28%**, khiến người chơi bị kẹt lại sau nhiều lần thử (nhiều user có trên 10+ lần thử nhưng không qua được) dẫn đến ức chế và churn.
* **Khoảng cách trải nghiệm giữa F2P và Payer:** Người chơi miễn phí (F2P) có D7 Retention cực thấp (**27.4%**) so với nhóm trả phí Payers (**91.7%**). Nhóm F2P phụ thuộc rất lớn vào tính năng hồi sinh (Revive - trung bình 5.45 lần/user), khi hết tài nguyên và gặp màn chơi quá khó (Ở Chapter 6), họ lập tức rời bỏ game.
* **Mức độ tương tác giảm dần theo thời gian:** Thời gian chơi (Playtime) và số lượng session của nhóm người chơi rời bỏ (Churned) tụt dốc không phanh từ sau Ngày 3 (D3), trùng khớp với thời điểm họ tiếp cận đến chương có độ khó cao.
* **Yếu tố kỹ thuật (Crash Rate):** Tỷ lệ crash trên các thiết bị cấu hình thấp (Low-tier device) có cao hơn (~5.5% - 6.4%) nhưng nhìn chung ổn định qua các ngày, không phải nguyên nhân cốt lõi gây ra đợt sụt giảm Retention đột biến này.

---

## 🛠️ Công Cụ & Công Nghệ Sử Dụng

* **Database:** `DuckDB` (Nhỏ gọn, tối ưu cho phân tích dữ liệu dạng bảng).
* **Ngôn ngữ truy vấn:** `SQL` (Window Functions, Cohort Aggregation).
* **Ngôn ngữ phân tích & Trực quan hóa:** `Python` (`Pandas`, `Seaborn`, `Matplotlib`).
* **Môi trường làm việc:** `Jupyter Notebook`.

---

## 🚀 Hướng Dẫn Tiếp Cận Dự Án

1. **Xem mã nguồn truy vấn:** Truy cập thư mục `/sql/sql_ad_hoc_query.sql` để xem cách trích xuất dữ liệu Cohort, tỷ lệ Crash, phân thục người chơi và hành vi vượt màn.
2. **Xem quá trình phân tích & biểu đồ:** Mở file `/notebooks/visualize.ipynb` để theo dõi quy trình kết nối database, phân tích dữ liệu bằng Python và các bước trực quan hóa.
3. **Đọc báo cáo hoàn chỉnh:** Để hiểu sâu hơn về bối cảnh, luận điểm phân tích và các đề xuất giải pháp (như điều chỉnh lại độ khó màn chơi, tối ưu hóa phần thưởng hồi sinh cho F2P), vui lòng đọc file **[D7_Retention_Drop_Analysis_Report.pdf](https://github.com/hoan110102/D7_Retention_Drop_Analysis/blob/main/report/D7_Retention_Drop_Analysis_Report.pdf)**.
