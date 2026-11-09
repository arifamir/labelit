# The Linux build environment: Swift, plus what LabelIt uses there (llama.cpp's build tools, libheif with its HEVC
# and AV1 decoders, Tesseract with English). `make linux-test` builds this image and runs the tests in it.
FROM swift:6.3-noble
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake ninja-build pkg-config git ca-certificates \
      libheif-dev libheif-plugin-libde265 libheif-plugin-dav1d \
      libtesseract-dev tesseract-ocr-eng tesseract-ocr-swe \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
