#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>

static void check(cudaError_t status, const char* operation) {
    if (status == cudaSuccess) {
        return;
    }

    std::fprintf(stderr, "%s failed: %s\n", operation,
                 cudaGetErrorString(status));
    std::exit(EXIT_FAILURE);
}

int main() {
    int runtime_version = 0;
    int device_count = 0;
    check(cudaRuntimeGetVersion(&runtime_version), "cudaRuntimeGetVersion");
    check(cudaGetDeviceCount(&device_count), "cudaGetDeviceCount");

    if (device_count < 1) {
        std::fprintf(stderr, "No CUDA GPU is visible to the container.\n");
        return EXIT_FAILURE;
    }

    cudaDeviceProp properties{};
    check(cudaGetDeviceProperties(&properties, 0), "cudaGetDeviceProperties");
    check(cudaSetDevice(0), "cudaSetDevice");

    void* allocation = nullptr;
    check(cudaMalloc(&allocation, 1024), "cudaMalloc");
    check(cudaMemset(allocation, 0, 1024), "cudaMemset");
    check(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    check(cudaFree(allocation), "cudaFree");

    std::printf("CUDA runtime: %d\n", runtime_version);
    std::printf("GPU count visible to job: %d\n", device_count);
    std::printf("GPU 0: %s\n", properties.name);
    std::printf("GPU 0 compute capability: %d.%d\n", properties.major,
                properties.minor);
    std::printf("GPU 0 memory: %.0f MiB\n",
                static_cast<double>(properties.totalGlobalMem) /
                    (1024.0 * 1024.0));
    std::puts("CUDA allocation test: OK");
    return EXIT_SUCCESS;
}
