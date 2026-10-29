# 01_analysis.R
# Boston 311 service requests, 2018–2022: response-time analysis
# Input:  data/boston311_2018_2022.rds  (built by 00_build_dataset.R)
# Output: outputs/figures/*.png, outputs/tables/*.csv

library(tidyverse)   # includes lubridate
library(glmnet)

set.seed(123)


# ---- 1. Load and prepare -------------------------------------------------

raw <- readRDS("data/boston311_2018_2022.rds")

# Keep only the columns the analysis uses (saves memory)
data <- raw %>%
  select(open_dt, closed_dt, case_status, reason, type,
         department, neighborhood, source) %>%
  mutate(
    open_dt       = ymd_hms(open_dt),
    closed_dt     = ymd_hms(closed_dt),
    year          = year(open_dt),
    response_time = as.numeric(difftime(closed_dt, open_dt, units = "hours"))
  )

rm(raw); gc()

cat("Total requests:                ", nrow(data), "\n")
cat("Failed to parse open_dt:       ", sum(is.na(data$open_dt)), "\n")
cat("No closed date (still open):   ", sum(is.na(data$response_time)), "\n")

# Modeling data: closed cases with a valid response time and no missing predictors.
# Open cases have no response time, so they are excluded (see README limitations).
model_data <- data %>%
  filter(!is.na(response_time), response_time >= 0) %>%
  drop_na(type, department, neighborhood, source)

cat("Rows used for modeling:        ", nrow(model_data), "\n")


# ---- 2. Response time by year --------------------------------------------

summary_by_year <- model_data %>%
  group_by(year) %>%
  summarise(
    requests     = n(),
    mean_hours   = mean(response_time),
    median_hours = median(response_time)
  )

print(summary_by_year)
write_csv(summary_by_year, "outputs/tables/response_time_by_year.csv")


# ---- Q1. Most common request reasons over time ---------------------------
# Uses all requests (open and closed), since this is about volume, not speed.

top_reasons <- data %>%
  filter(!is.na(reason)) %>%
  count(reason, sort = TRUE) %>%
  slice_head(n = 8) %>%
  pull(reason)

trend_data <- data %>%
  filter(reason %in% top_reasons) %>%
  count(year, reason)

p1 <- ggplot(trend_data, aes(x = year, y = n, color = reason)) +
  geom_line(linewidth = 1) +
  geom_point() +
  scale_y_continuous(labels = scales::comma) +
  labs(title = "Top 8 Service Request Reasons, 2018–2022",
       x = "Year", y = "Number of requests", color = "Reason") +
  theme_minimal()

ggsave("outputs/figures/01_request_trends.png", p1, width = 9, height = 5, dpi = 300)


# ---- Q2. Response time by submission source ------------------------------

model_source <- lm(response_time ~ source, data = model_data)
source_coefs <- broom::tidy(model_source, conf.int = TRUE)

print(source_coefs)
write_csv(source_coefs, "outputs/tables/source_model_coefficients.csv")

rm(model_source); gc()

# Log scale so the boxes are readable despite extreme outliers
p2 <- ggplot(model_data, aes(x = source, y = response_time)) +
  geom_boxplot(outlier.shape = NA) +
  scale_y_continuous(
    trans  = "log1p",
    breaks = c(0, 1, 24, 168, 720, 8760),
    labels = c("0", "1 hr", "1 day", "1 week", "30 days", "1 year")
  ) +
  labs(title = "Response Time by Submission Source (log scale)",
       x = "Source", y = "Response time") +
  theme_bw() +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))

ggsave("outputs/figures/02_response_time_by_source.png", p2, width = 9, height = 5, dpi = 300)


# ---- Q3. Change in response time over the years --------------------------
# Linear regression controlling for department, neighborhood, type and source.
# (Replaces stepAIC from the course version, which is very slow at 1.3M rows.)

model_full <- lm(response_time ~ year + department + neighborhood + type + source,
                 data = model_data, model = FALSE)

full_coefs <- broom::tidy(model_full, conf.int = TRUE)
write_csv(full_coefs, "outputs/tables/full_model_coefficients.csv")

rm(model_full); gc()

year_effect <- full_coefs %>% filter(term == "year")
print(year_effect)
print(full_coefs %>% filter(term == "sourceCity Worker App"))

# Express the yearly change relative to the 2018 average
baseline_2018 <- summary_by_year$mean_hours[summary_by_year$year == 2018]
cat("Yearly change as % of 2018 mean:",
    round(year_effect$estimate / baseline_2018 * 100, 1), "%\n")

p3 <- ggplot(summary_by_year, aes(x = year, y = mean_hours)) +
  geom_line() +
  geom_point(color = "red", size = 2) +
  labs(title = "Average Response Time by Year, 2018–2022",
       x = "Year", y = "Mean response time (hours)") +
  theme_bw()

ggsave("outputs/figures/03_response_time_by_year.png", p3, width = 8, height = 4.5, dpi = 300)


# ---- Q4. Fastest and slowest request types (LASSO) -----------------------

x <- model.matrix(response_time ~ year + department + neighborhood + type + source,
                  data = model_data)[, -1]
y <- model_data$response_time

lasso_cv <- cv.glmnet(x, y, alpha = 1)

png("outputs/figures/04_lasso_cv.png", width = 8, height = 5, units = "in", res = 300)
plot(lasso_cv)
dev.off()

lasso_pred <- predict(lasso_cv, newx = x, s = "lambda.min")

lasso_metrics <- tibble(
  metric = c("lambda.min", "lambda.1se", "CV RMSE (lambda.min)", "Training RMSE"),
  value  = c(lasso_cv$lambda.min,
             lasso_cv$lambda.1se,
             sqrt(min(lasso_cv$cvm)),
             sqrt(mean((y - lasso_pred)^2)))
)

print(lasso_metrics)
write_csv(lasso_metrics, "outputs/tables/lasso_metrics.csv")

# Request-type coefficients: most negative = fastest, most positive = slowest
type_coefs <- coef(lasso_cv, s = "lambda.min") %>%
  as.matrix() %>%
  as.data.frame() %>%
  rownames_to_column("term") %>%
  rename(estimate = 2) %>%
  filter(str_starts(term, "type"), estimate != 0) %>%
  mutate(term = str_remove(term, "^type")) %>%
  arrange(estimate)

cat("\nFastest request types:\n"); print(head(type_coefs, 5))
cat("\nSlowest request types:\n"); print(tail(type_coefs, 5))
write_csv(type_coefs, "outputs/tables/lasso_type_coefficients.csv")

rm(x, y, lasso_pred); gc()


# ---- Q5. Do neighborhoods report different issues? -----------------------

# Many neighborhood/type pairs are rare, so R warns the approximation may be off;
# with 1.3M rows the result is significant either way.
chi <- suppressWarnings(
  chisq.test(table(model_data$neighborhood, model_data$type))
)

chi_results <- tibble(
  test       = "Chi-square test of independence",
  chi_square = unname(chi$statistic),
  df         = unname(chi$parameter),
  p_value    = chi$p.value
)

print(chi_results)
write_csv(chi_results, "outputs/tables/chi_square_neighborhood_type.csv")

top_types <- model_data %>% count(type, sort = TRUE) %>% slice_head(n = 6) %>% pull(type)
top_hoods <- model_data %>% count(neighborhood, sort = TRUE) %>% slice_head(n = 6) %>% pull(neighborhood)

heatmap_data <- model_data %>%
  filter(type %in% top_types, neighborhood %in% top_hoods) %>%
  count(neighborhood, type) %>%
  mutate(neighborhood = factor(neighborhood, levels = top_hoods),
         type         = factor(type, levels = top_types))

p5 <- ggplot(heatmap_data, aes(x = type, y = neighborhood, fill = n)) +
  geom_tile(color = "white", linewidth = 0.5) +
  scale_fill_viridis_c(option = "plasma", name = "Requests", labels = scales::comma) +
  labs(title = "Top 6 Request Types by Neighborhood, 2018–2022",
       x = "Request type", y = "Neighborhood") +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1),
        panel.grid  = element_blank())

ggsave("outputs/figures/05_neighborhood_heatmap.png", p5, width = 9, height = 6, dpi = 300)


# ---- Record package versions for reproducibility -------------------------
writeLines(capture.output(sessionInfo()), "outputs/session_info.txt")

cat("\nDone. Figures in outputs/figures, tables in outputs/tables.\n")