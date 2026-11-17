#include "capture_linux.h"

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "../common.h"
#include "ipc.h"
#include "rgb_to_nv12.spv.h"

namespace {

#define VKC(x)                                              \
  do {                                                      \
    VkResult r_ = (x);                                      \
    if (r_ != VK_SUCCESS) {                                 \
      LvLog("%s failed (%d)", #x, int(r_));                 \
      return false;                                         \
    }                                                       \
  } while (0)

bool ReadExactly(int fd, void* out, size_t size, const std::atomic<bool>& running) {
  auto* p = static_cast<uint8_t*>(out);
  while (size > 0 && running) {
    pollfd pfd{fd, POLLIN, 0};
    int c = poll(&pfd, 1, 100);
    if (c < 0 && errno != EINTR) return false;
    if (c <= 0) continue;
    ssize_t n = read(fd, p, size);
    if (n == 0) return false;  // compositor closed the socket
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      return false;
    }
    p += n;
    size -= size_t(n);
  }
  return size == 0;
}

// Reads the newest complete packet, dropping older queued ones (the encoder only wants the latest frame).
bool ReadLatest(int fd, present_packet* out, const std::atomic<bool>& running) {
  if (!ReadExactly(fd, out, sizeof *out, running)) return false;
  for (;;) {
    pollfd pfd{fd, POLLIN, 0};
    if (poll(&pfd, 1, 0) <= 0) return true;
    if (!ReadExactly(fd, out, sizeof *out, running)) return false;
  }
}

bool ReceiveFds(int fd, std::vector<int>* fds) {
  char data[1];
  iovec iov{data, 1};
  union {
    cmsghdr align;
    char buf[CMSG_SPACE(sizeof(int) * 16)];
  } ctrl;
  msghdr msg{};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = ctrl.buf;
  msg.msg_controllen = sizeof ctrl.buf;
  ssize_t n;
  do {
    n = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) return false;
  for (cmsghdr* c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
      size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      fds->resize(count);
      memcpy(fds->data(), CMSG_DATA(c), count * sizeof(int));
      return true;
    }
  }
  return false;
}

bool IsSrgb(VkFormat f) {
  switch (f) {
    case VK_FORMAT_B8G8R8A8_SRGB:
    case VK_FORMAT_R8G8B8A8_SRGB:
    case VK_FORMAT_A8B8G8R8_SRGB_PACK32:
      return true;
    default:
      return false;
  }
}

// Everything the GPU side needs for one connection of the compositor.
struct Gpu {
  VkInstance instance = VK_NULL_HANDLE;
  VkPhysicalDevice phys = VK_NULL_HANDLE;
  VkDevice device = VK_NULL_HANDLE;
  VkQueue queue = VK_NULL_HANDLE;
  uint32_t queueFamily = 0;
  LinuxEncoder::Gpu info;
  PFN_vkImportSemaphoreFdKHR importSemaphoreFd = nullptr;
  bool noSemaphores = false;

  struct Image {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkSemaphore semaphore = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
    bool initialized = false;
  };
  std::vector<Image> images;
  VkFormat format = VK_FORMAT_UNDEFINED;
  uint32_t srcWidth = 0, srcHeight = 0;

  VkSampler sampler = VK_NULL_HANDLE;
  VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
  VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
  VkShaderModule shader = VK_NULL_HANDLE;
  VkPipeline pipeline = VK_NULL_HANDLE;
  VkDescriptorPool pool = VK_NULL_HANDLE;
  VkBuffer out = VK_NULL_HANDLE;
  VkDeviceMemory outMemory = VK_NULL_HANDLE;
  void* outMapped = nullptr;
  VkDeviceSize outSize = 0;
  VkCommandPool cmdPool = VK_NULL_HANDLE;
  VkCommandBuffer cmd = VK_NULL_HANDLE;
  VkFence fence = VK_NULL_HANDLE;

  ~Gpu() {
    if (device) {
      vkDeviceWaitIdle(device);
      if (fence) vkDestroyFence(device, fence, nullptr);
      if (cmdPool) vkDestroyCommandPool(device, cmdPool, nullptr);
      if (outMapped) vkUnmapMemory(device, outMemory);
      if (out) vkDestroyBuffer(device, out, nullptr);
      if (outMemory) vkFreeMemory(device, outMemory, nullptr);
      if (pool) vkDestroyDescriptorPool(device, pool, nullptr);
      if (pipeline) vkDestroyPipeline(device, pipeline, nullptr);
      if (shader) vkDestroyShaderModule(device, shader, nullptr);
      if (pipelineLayout) vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
      if (setLayout) vkDestroyDescriptorSetLayout(device, setLayout, nullptr);
      if (sampler) vkDestroySampler(device, sampler, nullptr);
      for (auto& im : images) {
        if (im.view) vkDestroyImageView(device, im.view, nullptr);
        if (im.image) vkDestroyImage(device, im.image, nullptr);
        if (im.memory) vkFreeMemory(device, im.memory, nullptr);
        if (im.semaphore) vkDestroySemaphore(device, im.semaphore, nullptr);
      }
      vkDestroyDevice(device, nullptr);
    }
    if (instance) vkDestroyInstance(instance, nullptr);
  }

  bool Init(const uint8_t uuid[VK_UUID_SIZE]) {
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "Localview SteamVR driver";
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    VKC(vkCreateInstance(&ici, nullptr, &instance));

    uint32_t n = 0;
    vkEnumeratePhysicalDevices(instance, &n, nullptr);
    std::vector<VkPhysicalDevice> devs(n);
    vkEnumeratePhysicalDevices(instance, &n, devs.data());
    for (auto d : devs) {
      VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
      VkPhysicalDeviceProperties2 p2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
      p2.pNext = &id;
      vkGetPhysicalDeviceProperties2(d, &p2);
      if (memcmp(id.deviceUUID, uuid, VK_UUID_SIZE) == 0) {
        phys = d;
        info.vendorId = p2.properties.vendorID;
        LvLog("GPU: %s", p2.properties.deviceName);
        break;
      }
    }
    if (!phys) {
      LvLog("the GPU SteamVR renders on was not found");
      return false;
    }

    // Render node for VA-API (VK_EXT_physical_device_drm), so the encoder uses the same GPU.
    uint32_t extCount = 0;
    vkEnumerateDeviceExtensionProperties(phys, nullptr, &extCount, nullptr);
    std::vector<VkExtensionProperties> exts(extCount);
    vkEnumerateDeviceExtensionProperties(phys, nullptr, &extCount, exts.data());
    auto has = [&](const char* name) {
      for (auto& e : exts)
        if (strcmp(e.extensionName, name) == 0) return true;
      return false;
    };
    if (has(VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME)) {
      VkPhysicalDeviceDrmPropertiesEXT drm{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
      VkPhysicalDeviceProperties2 p2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
      p2.pNext = &drm;
      vkGetPhysicalDeviceProperties2(phys, &p2);
      if (drm.hasRender) info.renderNode = "/dev/dri/renderD" + std::to_string(drm.renderMinor);
    }
    // Test hook (vr/linux/test): software Vulkan cannot share semaphores, the fake compositor finishes each frame first.
    noSemaphores = getenv("LOCALVIEW_VR_TEST") != nullptr && !has(VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME);
    if (!has(VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME) || (!has(VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME) && !noSemaphores)) {
      LvLog("the GPU driver cannot share frames between processes (external memory/semaphore fd)");
      return false;
    }

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, nullptr);
    std::vector<VkQueueFamilyProperties> qf(qn);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, qf.data());
    bool found = false;
    for (uint32_t i = 0; i < qn && !found; i++) {
      if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
        queueFamily = i;
        found = true;
      }
    }
    if (!found) return false;
    float prio = 1.f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = queueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    const char* devExts[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME};
    VkPhysicalDeviceVulkan12Features f12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    f12.timelineSemaphore = VK_TRUE;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.pNext = &f12;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = noSemaphores ? 1 : 2;
    dci.ppEnabledExtensionNames = devExts;
    VKC(vkCreateDevice(phys, &dci, nullptr, &device));
    vkGetDeviceQueue(device, queueFamily, 0, &queue);
    importSemaphoreFd = reinterpret_cast<PFN_vkImportSemaphoreFdKHR>(vkGetDeviceProcAddr(device, "vkImportSemaphoreFdKHR"));
    return noSemaphores || importSemaphoreFd != nullptr;
  }

  bool ImportImage(VkImageCreateInfo ci, uint32_t memIndex, int memFd, int semFd) {
    Image im;
    VkExternalMemoryImageCreateInfo ext{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    ci.pNext = &ext;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.queueFamilyIndexCount = 0;
    ci.pQueueFamilyIndices = nullptr;
    ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VKC(vkCreateImage(device, &ci, nullptr, &im.image));
    images.push_back(im);
    Image& m = images.back();
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, m.image, &req);
    VkMemoryDedicatedAllocateInfo ded{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    ded.image = m.image;
    VkImportMemoryFdInfoKHR imp{VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR};
    imp.pNext = &ded;
    imp.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    imp.fd = memFd;  // ownership passes to Vulkan on success
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    mai.pNext = &imp;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = memIndex;
    VKC(vkAllocateMemory(device, &mai, nullptr, &m.memory));
    VKC(vkBindImageMemory(device, m.image, m.memory, 0));

    if (noSemaphores) {
      close(semFd);
    } else {
      VkSemaphoreTypeCreateInfo tl{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
      tl.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
      VkSemaphoreCreateInfo sci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
      sci.pNext = &tl;
      VKC(vkCreateSemaphore(device, &sci, nullptr, &m.semaphore));
      VkImportSemaphoreFdInfoKHR isi{VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR};
      isi.semaphore = m.semaphore;
      isi.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
      isi.fd = semFd;
      VKC(importSemaphoreFd(device, &isi));
    }

    VkImageViewCreateInfo vci{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    vci.image = m.image;
    vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vci.format = ci.format;
    vci.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VKC(vkCreateImageView(device, &vci, nullptr, &m.view));
    format = ci.format;
    srcWidth = ci.extent.width;
    srcHeight = ci.extent.height;
    return true;
  }

  bool CreatePipeline(uint32_t width, uint32_t height) {
    VkSamplerCreateInfo smp{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    smp.magFilter = smp.minFilter = VK_FILTER_NEAREST;
    smp.addressModeU = smp.addressModeV = smp.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    VKC(vkCreateSampler(device, &smp, nullptr, &sampler));

    VkDescriptorSetLayoutBinding b[2] = {};
    b[0].binding = 0;
    b[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    b[0].descriptorCount = 1;
    b[0].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    b[1].binding = 1;
    b[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    b[1].descriptorCount = 1;
    b[1].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo dl{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    dl.bindingCount = 2;
    dl.pBindings = b;
    VKC(vkCreateDescriptorSetLayout(device, &dl, nullptr, &setLayout));
    VkPushConstantRange pcr{VK_SHADER_STAGE_COMPUTE_BIT, 0, 5 * sizeof(uint32_t)};
    VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pl.setLayoutCount = 1;
    pl.pSetLayouts = &setLayout;
    pl.pushConstantRangeCount = 1;
    pl.pPushConstantRanges = &pcr;
    VKC(vkCreatePipelineLayout(device, &pl, nullptr, &pipelineLayout));
    VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    sm.codeSize = sizeof(kRgbToNv12);
    sm.pCode = kRgbToNv12;
    VKC(vkCreateShaderModule(device, &sm, nullptr, &shader));
    VkComputePipelineCreateInfo cp{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    cp.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    cp.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cp.stage.module = shader;
    cp.stage.pName = "main";
    cp.layout = pipelineLayout;
    VKC(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cp, nullptr, &pipeline));

    // NV12 output, read back by the CPU and piped to the encoder.
    outSize = VkDeviceSize(width) * height * 3 / 2;
    VkBufferCreateInfo bci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bci.size = outSize;
    bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    VKC(vkCreateBuffer(device, &bci, nullptr, &out));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, out, &req);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    int type = -1;
    const VkMemoryPropertyFlags want[] = {
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT};
    for (auto w : want) {
      for (uint32_t i = 0; i < mp.memoryTypeCount && type < 0; i++) {
        if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & w) == w) type = int(i);
      }
      if (type >= 0) break;
    }
    if (type < 0) return false;
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = uint32_t(type);
    VKC(vkAllocateMemory(device, &mai, nullptr, &outMemory));
    VKC(vkBindBufferMemory(device, out, outMemory, 0));
    VKC(vkMapMemory(device, outMemory, 0, VK_WHOLE_SIZE, 0, &outMapped));

    VkDescriptorPoolSize ps[2] = {{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, uint32_t(images.size())},
                                  {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, uint32_t(images.size())}};
    VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dp.maxSets = uint32_t(images.size());
    dp.poolSizeCount = 2;
    dp.pPoolSizes = ps;
    VKC(vkCreateDescriptorPool(device, &dp, nullptr, &pool));
    for (auto& im : images) {
      VkDescriptorSetAllocateInfo da{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
      da.descriptorPool = pool;
      da.descriptorSetCount = 1;
      da.pSetLayouts = &setLayout;
      VKC(vkAllocateDescriptorSets(device, &da, &im.set));
      VkDescriptorImageInfo ii{sampler, im.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
      VkDescriptorBufferInfo bi{out, 0, outSize};
      VkWriteDescriptorSet w[2] = {{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET}, {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET}};
      w[0].dstSet = im.set;
      w[0].dstBinding = 0;
      w[0].descriptorCount = 1;
      w[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
      w[0].pImageInfo = &ii;
      w[1].dstSet = im.set;
      w[1].dstBinding = 1;
      w[1].descriptorCount = 1;
      w[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
      w[1].pBufferInfo = &bi;
      vkUpdateDescriptorSets(device, 2, w, 0, nullptr);
    }

    VkCommandPoolCreateInfo cpi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpi.queueFamilyIndex = queueFamily;
    VKC(vkCreateCommandPool(device, &cpi, nullptr, &cmdPool));
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cai.commandPool = cmdPool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    VKC(vkAllocateCommandBuffers(device, &cai, &cmd));
    VkFenceCreateInfo fci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VKC(vkCreateFence(device, &fci, nullptr, &fence));
    return true;
  }

  // Converts swapchain image `index` (ready once its timeline semaphore reaches `value`) into the NV12 buffer.
  bool Convert(uint32_t index, uint64_t value, uint32_t width, uint32_t height) {
    if (index >= images.size()) return false;
    Image& im = images[index];
    VKC(vkResetCommandBuffer(cmd, 0));
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VKC(vkBeginCommandBuffer(cmd, &bi));
    if (!im.initialized) {
      // The image is only ever read here; it stays in SHADER_READ_ONLY afterwards (as in ALVR).
      VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
      b.srcAccessMask = 0;
      b.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
      b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      b.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
      b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      b.image = im.image;
      b.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 0,
                           nullptr, 1, &b);
      im.initialized = true;
    }
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &im.set, 0, nullptr);
    uint32_t pc[5] = {width, height, srcWidth, srcHeight, IsSrgb(format) ? 1u : 0u};
    vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, pc);
    vkCmdDispatch(cmd, (width / 4 + 7) / 8, (height / 2 + 7) / 8, 1);
    VkBufferMemoryBarrier bb{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
    bb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    bb.srcQueueFamilyIndex = bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bb.buffer = out;
    bb.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &bb, 0,
                         nullptr);
    VKC(vkEndCommandBuffer(cmd));

    VkTimelineSemaphoreSubmitInfo ts{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    ts.waitSemaphoreValueCount = 1;
    ts.pWaitSemaphoreValues = &value;
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.pNext = &ts;
    si.waitSemaphoreCount = im.semaphore ? 1 : 0;
    si.pWaitSemaphores = &im.semaphore;
    si.pWaitDstStageMask = &stage;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    VKC(vkResetFences(device, 1, &fence));
    VKC(vkQueueSubmit(queue, 1, &si, fence));
    VKC(vkWaitForFences(device, 1, &fence, VK_TRUE, 1000000000ull));
    return true;
  }
};

}  // namespace

bool LinuxStreamer::Start(uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, FrameRecorder recorder,
                          LinuxEncoder::Output out) {
  width_ = width;
  height_ = height;
  fps_ = fps;
  bitrate_ = bitrateMbps;
  recorder_ = std::move(recorder);
  out_ = std::move(out);
  const char* rt = getenv("XDG_RUNTIME_DIR");
  socketPath_ = std::string(rt && *rt ? rt : "/tmp") + "/localview-vr-ipc";
  unlink(socketPath_.c_str());
  listen_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (listen_ < 0) return false;
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, socketPath_.c_str(), sizeof addr.sun_path - 1);
  if (bind(listen_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0 || listen(listen_, 4) != 0) {
    LvLog("cannot listen on %s (%d)", socketPath_.c_str(), errno);
    close(listen_);
    listen_ = -1;
    return false;
  }
  running_ = true;
  thread_ = std::thread([this] { Run(); });
  LvLog("waiting for SteamVR's compositor on %s", socketPath_.c_str());
  return true;
}

void LinuxStreamer::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  if (listen_ >= 0) close(listen_);
  listen_ = -1;
  unlink(socketPath_.c_str());
}

void LinuxStreamer::Run() {
  while (running_) {
    pollfd pfd{listen_, POLLIN, 0};
    if (poll(&pfd, 1, 100) <= 0) continue;
    int client = accept4(listen_, nullptr, nullptr, SOCK_CLOEXEC);
    if (client < 0) continue;

    init_packet init{};
    std::vector<int> fds;
    if (!ReadExactly(client, &init, sizeof init, running_) || !ReceiveFds(client, &fds) ||
        fds.size() < size_t(init.num_images) * 2 || init.num_images == 0) {
      LvLog("the compositor did not send its frames");
      for (int fd : fds) close(fd);
      close(client);
      continue;
    }
    LvLog("compositor connected (pid %d): %u images %ux%u, format %d", int(init.source_pid), init.num_images,
          init.image_create_info.extent.width, init.image_create_info.extent.height, int(init.image_create_info.format));
    {
      Gpu gpu;
      bool ok = gpu.Init(init.device_uuid.data());
      size_t used = 0;
      for (uint32_t i = 0; ok && i < init.num_images; i++) {
        VkImageCreateInfo ci = init.image_create_info;
        ci.pNext = nullptr;
        ok = gpu.ImportImage(ci, uint32_t(init.mem_index), fds[2 * i], fds[2 * i + 1]);
        used = 2 * i + 2;
      }
      for (size_t i = used; i < fds.size(); i++) close(fds[i]);
      ok = ok && gpu.CreatePipeline(width_, height_);
      LinuxEncoder enc;
      ok = ok && enc.Init(gpu.info, width_, height_, fps_, bitrate_, out_);
      if (!ok) LvLog("PC VR streaming could not start on this PC (see the messages above)");
      present_packet p{};
      while (running_ && ReadLatest(client, &p, running_)) {
        if (!ok) continue;  // keep the compositor's socket drained
        vr::HmdMatrix34_t m;
        memcpy(&m, p.pose, sizeof m);
        uint64_t frame = recorder_(m);
        if (!gpu.Convert(p.image, p.semaphore_value, width_, height_)) continue;
        if (getenv("LOCALVIEW_VR_TEST_TRACE")) {
          const uint8_t* y = static_cast<const uint8_t*>(gpu.outMapped);
          LvLog("trace: image %u pose %.0f -> Y(left)=%u Y(right)=%u", p.image, double(m.m[0][3]),
                y[(height_ / 2) * width_ + width_ / 4], y[(height_ / 2) * width_ + 3 * width_ / 4]);
        }
        if (!enc.Submit(static_cast<const uint8_t*>(gpu.outMapped), size_t(gpu.outSize), frame)) {
          LvLog("encoder stopped; PC VR video ended");
          ok = false;
        }
      }
      enc.Shutdown();
    }
    close(client);
    LvLog("compositor disconnected");
  }
}
