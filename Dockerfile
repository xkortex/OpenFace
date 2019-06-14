# ==================== Building Model Layer ===========================
# This is a little trick to improve caching and minimize rebuild time
# and bandwidth. Note that RUN commands only cache-miss if the prior layers
# miss, or the dockerfile changes prior to this step.
# To update these patch files, be sure to run build with --no-cache
FROM alpine as model_data
RUN apk --no-cache --update-cache add wget
WORKDIR /data/patch_experts

RUN wget -q https://www.dropbox.com/s/7na5qsjzz8yfoer/cen_patches_0.25_of.dat &&\
    wget -q https://www.dropbox.com/s/k7bj804cyiu474t/cen_patches_0.35_of.dat &&\
    wget -q https://www.dropbox.com/s/ixt4vkbmxgab1iu/cen_patches_0.50_of.dat &&\
    wget -q https://www.dropbox.com/s/2t5t1sdpshzfhpj/cen_patches_1.00_of.dat

# ==================== Install Ubuntu Base libs ===========================

FROM ubuntu:18.04 as ubuntu_base

LABEL maintainer="Edgar Aroutiounian <edgar.factorial@gmail.com>"

ARG DEBIAN_FRONTEND=noninteractive

# todo: minimize this even more
RUN apt-get update -qq && apt-get install -qq curl \
    && apt-get install -qq --no-install-recommends \
        cmake \
        libc++abi-dev libopenblas-dev liblapack-dev \
        pkg-config libavcodec-dev libavformat-dev libswscale-dev \
        libtbb2 libtbb-dev libjpeg-dev \
        libpng-dev libtiff-dev \
        libboost-all-dev  && \
    rm -rf /var/lib/apt/lists/*

# Tip: Install pip with get-pip is official preffered method
RUN curl --silent --show-error \
    https://bootstrap.pypa.io/get-pip.py | python2 &&\
    pip2 install --no-cache-dir numpy==1.16

# ==================== Build-time dependency libs ======================
# This will build and install opencv and dlib into an additional dummy
# directory, /root/diff, so we can later copy in these artifacts,
# minimizing docker layer size
FROM ubuntu_base as cv_deps

WORKDIR /root/build-dep
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -qq -y \
        build-essential llvm clang-3.7 libc++-dev \
        python-dev git checkinstall&& \
    rm -rf /var/lib/apt/lists/*

# ==================== Building dlib ===========================

RUN curl http://dlib.net/files/dlib-19.13.tar.bz2 -LO &&\
    tar xf dlib-19.13.tar.bz2 && \
    rm dlib-19.13.tar.bz2 &&\
    mv dlib-19.13 dlib &&\
    mkdir -p dlib/build &&\
    cd dlib/build &&\
    cmake -DCMAKE_BUILD_TYPE=Release .. &&\
    make -j "$((`nproc`<2?1:$((`nproc`-1))))" && \
    make install && \
    DESTDIR=/root/diff make install &&\
    ldconfig

# ==================== Building OpenCV ======================
ENV OPENCV_VERSION=3.4.6

RUN curl https://github.com/opencv/opencv/archive/${OPENCV_VERSION}.tar.gz -LO &&\
    tar xf ${OPENCV_VERSION}.tar.gz && \
    rm ${OPENCV_VERSION}.tar.gz &&\
    mv opencv-${OPENCV_VERSION} opencv && \
    mkdir -p opencv/build && \
    cd opencv/build && \
    cmake -D CMAKE_BUILD_TYPE=RELEASE \
    -D CMAKE_INSTALL_PREFIX=/usr/local \
    -D WITH_TBB=ON -D WITH_CUDA=OFF \
    -DWITH_QT=OFF -DWITH_GTK=OFF\
    .. && \
    make -j "$((`nproc`<2?1:$((`nproc`-1))))" && \
    make install &&\
    DESTDIR=/root/diff make install

# ==================== Building OpenFace ===========================
FROM cv_deps as openface
WORKDIR /root/openface

COPY ./CMakeLists.txt ./

COPY ./cmake ./cmake

COPY ./exe ./exe

COPY ./lib ./lib

COPY --from=model_data /data/patch_experts/* \
    /root/openface/lib/local/LandmarkDetector/model/patch_experts/

RUN mkdir -p build && cd build && \
    cmake -D CMAKE_BUILD_TYPE=RELEASE .. && \
    make -j "$((`nproc`<2?1:$((`nproc`-1))))" &&\
    DESTDIR=/root/diff make install


# ==================== Streamline container ===========================
# Clean up - start fresh and only copy in necessary stuff
# This shrinks the image from ~8 GB to ~1.6 GB
FROM ubuntu_base as final

WORKDIR /root

# Copy in only necessary libraries
COPY --from=openface /root/diff /

RUN ldconfig
