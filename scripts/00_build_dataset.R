# 00_build_dataset.R
# Combines the 2018–2022 Boston 311 yearly files into one dataset
# Source: https://data.boston.gov/dataset/311-service-requests

library(tidyverse)

# 1. List the five yearly files
files <- list.files("data/raw", pattern = "^311_\\d{4}\\.csv$", full.names = TRUE)
print(files)

# 2. Read each one with every column as text, then stack them
yearly <- map(files, read_csv, col_types = cols(.default = "c"))

# Check that all files have the same columns before stacking
map(yearly, names) %>% unique() %>% length()   # should print 1

data <- bind_rows(yearly)

# 3. Check: row count, column count and open_dt range
nrow(data)
ncol(data)
range(data$open_dt, na.rm = TRUE)

# 4. Save
saveRDS(data, "data/boston311_2018_2022.rds")

print(map(yearly, names) %>% unique() %>% length())
print(nrow(data))
print(ncol(data))
print(range(data$open_dt, na.rm = TRUE))