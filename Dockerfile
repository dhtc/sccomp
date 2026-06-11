FROM bioconductor/bioconductor_docker@sha256:8ce86a2dc913cc2176ec0b9b7153369576bb09ab2bc99bf88b28694e496bd57c

# -----------------------------------------------------------------------------
# Stage 1: 元数据 (Labels)
# -----------------------------------------------------------------------------
LABEL maintainer="dh908407543@gmail.com" \
      org.opencontainers.image.title="sccomp-bioconductor" \
      org.opencontainers.image.description="Bioconductor Docker image with sccomp pre-installed for single-cell composition analysis" \
      org.opencontainers.image.source="https://github.com/MangiolaLaboratory/sccomp" \
      org.opencontainers.image.licenses="GPL-3.0"

# -----------------------------------------------------------------------------
# Stage 2: 构建参数
# -----------------------------------------------------------------------------
ARG SCCOMP_VERSION="2.1.30"
ARG CMDSTAN_VERSION="2.36.0"  # CmdStan 版本 (与 cmdstanr 兼容)
ARG BIOC_VERSION="3.23"        # Bioconductor 版本 (与基础镜像一致)

# -----------------------------------------------------------------------------
# Stage 3: 环境变量
# -----------------------------------------------------------------------------
# sccomp 在 R 进程内编译的 Stan 模型缓存目录
# 挂载卷时建议使用这个路径
ENV SCCOMP_CACHE_DIR="/home/rstudio/.sccomp_models" \
    SCCOMP_STAN_CACHE_DIR="/home/rstudio/.cmdstan/cmdstan-${CMDSTAN_VERSION}" \
    # 关闭 R 启动时的交互提示
    R_INTERACTIVE=false \
    # Bioconductor 版本 (必须与基础镜像匹配)
    BIOCONDUCTOR_VERSION=${BIOC_VERSION} \
    # 时区 (避免 lubridate 等包警告)
    TZ=Etc/UTC \
    # 避免 Docker 构建时下载超时
    DOCKER_BUILD=1

# -----------------------------------------------------------------------------
# Stage 4: 切换到 root 安装系统依赖
# -----------------------------------------------------------------------------
# bioconductor_docker 默认用户是 rstudio (uid 1000)
# 安装系统级依赖需要 root 权限
USER root

# 安装 CmdStan 编译所需的系统依赖
# - g++/make: C++14 编译 (sccomp 必需)
# - libssl-dev, libcurl-dev, libxml2-dev: 常用 R 包依赖
# - git, ca-certificates: cmdstanr 安装 CmdStan 时需要
# 注意: apt-get clean 减少镜像层大小
RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ \
        make \
        git \
        ca-certificates \
        libssl-dev \
        libcurl4-openssl-dev \
        libxml2-dev \
        libzmq3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# -----------------------------------------------------------------------------
# Stage 6: 安装 R 包依赖
# -----------------------------------------------------------------------------
# 顺序很重要,先安装核心依赖,再安装 sccomp
# 单一 RUN 减少镜像层数;|| true 允许 sccomp/cmdstanr 已通过其他方式安装

RUN R --no-save -e '
cat("=== 步骤 1/4: 安装 BiocManager ===\n")
if (!requireNamespace("BiocManager", quietly = TRUE)) {
    install.packages("BiocManager", quiet = TRUE)
}

cat("=== 步骤 2/4: 安装 sccomp 及其 Bioconductor 依赖 ===\n")
# sccomp 依赖 SingleCellExperiment (Bioconductor 包)
# 这里指定 version = "..." 可锁定版本
BiocManager::install(
    version = "'${BIOC_VERSION}'",
    ask = FALSE,
    update = FALSE
)

# 显式安装 sccomp 的 Bioconductor 依赖
BiocManager::install(
    c("SingleCellExperiment", "SummarizedExperiment", "S4Vectors"),
    ask = FALSE,
    update = FALSE
)

cat("=== 步骤 3/4: 安装 sccomp (来自 Bioconductor) ===\n")
# 推荐使用 Bioconductor 源 (经过 CRAN 验证)
# 或使用 GitHub 源 (开发版):
#   devtools::install_github("MangiolaLaboratory/sccomp", ref = "master")
BiocManager::install(
    "sccomp",
    version = "'${BIOC_VERSION}'",
    ask = FALSE,
    update = FALSE
)
' 2>&1 | tee /tmp/install_sccomp.log

# -----------------------------------------------------------------------------
# Stage 7: 安装 cmdstanr 和 CmdStan
# -----------------------------------------------------------------------------
# 这是 sccomp 安装说明的第 2 和第 3 步
# CmdStan 编译会下载源代码并构建 (约 5-10 分钟, 占用约 500MB)

RUN R --no-save -e '
cat("=== 步骤 4/4: 安装 cmdstanr + CmdStan ===\n")

# 从 r-universe 安装 cmdstanr (非 CRAN 包)
install.packages(
    "cmdstanr",
    repos = c("https://stan-dev.r-universe.dev", getOption("repos")),
    quiet = TRUE
)

# 检查并修复系统编译环境
cmdstanr::check_cmdstan_toolchain(fix = TRUE)

# 安装 CmdStan (会下载并编译 C++ 源码)
# cores = 0 表示使用所有可用核心加速编译
# quiet = TRUE 减少输出
cmdstanr::install_cmdstan(
    version = "'${CMDSTAN_VERSION}'",
    cores = parallel::detectCores(),
    quiet = FALSE
)

# 验证安装
cat("\n=== 验证 sccomp 和 cmdstanr 安装 ===\n")
library(sccomp)
library(cmdstanr)

cat("sccomp version:", as.character(packageVersion("sccomp")), "\n")
cat("cmdstanr version:", as.character(packageVersion("cmdstanr")), "\n")

# 验证 CmdStan 后端可用
cmdstan_version <- cmdstanr::cmdstan_version()
cat("CmdStan version:", cmdstan_version, "\n")
' 2>&1 | tee /tmp/install_cmdstan.log

# -----------------------------------------------------------------------------
# Stage 8: 验证 sccomp 功能 (smoke test)
# -----------------------------------------------------------------------------
# 运行 sccomp 文档中的最小示例,确保所有依赖就位
RUN R --no-save -e '
suppressPackageStartupMessages({
    library(sccomp)
})

cat("=== sccomp Smoke Test ===\n")

# 加载内置示例数据
data("counts_obj")

# 运行最小化分析 (cores=1 保证可复现)
set.seed(42)
result <- counts_obj |>
    sccomp_estimate(
        formula_composition = ~ type,
        sample = "sample",
        cell_group = "cell_group",
        abundance = "count",
        cores = 1,
        verbose = FALSE
    )

cat("\n=== 烟囱测试成功 ===\n")
print(head(result, 3))
' 2>&1 | tee /tmp/smoke_test.log

# -----------------------------------------------------------------------------
# Stage 9: 权限和目录设置
# -----------------------------------------------------------------------------
# 为 rstudio 用户创建 sccomp 缓存目录
# 建议在运行时通过 -v 挂载这个目录以保留缓存
RUN mkdir -p ${SCCOMP_CACHE_DIR} ${SCCOMP_STAN_CACHE_DIR} \
    && chown -R rstudio:rstudio ${SCCOMP_CACHE_DIR} ${SCCOMP_STAN_CACHE_DIR} \
    && chmod -R 775 ${SCCOMP_CACHE_DIR} ${SCCOMP_STAN_CACHE_DIR}

# -----------------------------------------------------------------------------
# Stage 10: 切换回默认用户
# -----------------------------------------------------------------------------
USER rstudio
WORKDIR /home/rstudio

# -----------------------------------------------------------------------------
# Stage 11: 暴露端口和元数据
# -----------------------------------------------------------------------------
# RStudio Server 端口 (来自基础镜像)
EXPOSE 8787
CMD ["/init"]
