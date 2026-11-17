// End-to-end test of the Linux PC VR frame path without SteamVR or a GPU:
// a fake compositor process shares Vulkan images + timeline semaphores over the
// same socket protocol as the capture layer, the driver's LinuxStreamer imports
// them, converts to NV12 and encodes with ffmpeg; the test then decodes the
// stream and checks the colours. Runs on Mesa lavapipe (software Vulkan).
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ipc.h"
#include "linux/capture_linux.h"

#define CHECK(x)                                                     \
  do {                                                               \
    VkResult r_ = (x);                                               \
    if (r_ != VK_SUCCESS) {                                          \
      fprintf(stderr, "compositor: %s failed (%d)\n", #x, int(r_)); \
      _exit(2);                                                      \
    }                                                                \
  } while (0)

static const uint32_t W = 512, H = 256;  // side-by-side, 256x256 per eye
static const int kFrames = 45;

// Frame f: left eye colour A, right eye colour B (sRGB-encoded bytes, BGRA order).
static void ColorsFor(int f, uint8_t a[3], uint8_t b[3]) {
  const uint8_t pal[5][3] = {{230, 40, 40}, {40, 200, 60}, {50, 70, 220}, {240, 240, 240}, {20, 20, 20}};
  memcpy(a, pal[f % 5], 3);
  memcpy(b, pal[(f + 2) % 5], 3);
}

static int FakeCompositor(const std::string& sock, VkFormat format) {
  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  app.apiVersion = VK_API_VERSION_1_2;
  VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  ici.pApplicationInfo = &app;
  VkInstance inst;
  CHECK(vkCreateInstance(&ici, nullptr, &inst));
  uint32_t n = 1;
  VkPhysicalDevice phys;
  vkEnumeratePhysicalDevices(inst, &n, &phys);
  float prio = 1;
  VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  q.queueCount = 1;
  q.pQueuePriorities = &prio;
  uint32_t extCount = 0;
  vkEnumerateDeviceExtensionProperties(phys, nullptr, &extCount, nullptr);
  std::vector<VkExtensionProperties> avail(extCount);
  vkEnumerateDeviceExtensionProperties(phys, nullptr, &extCount, avail.data());
  bool semFd = false;
  for (auto& e : avail) semFd |= strcmp(e.extensionName, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME) == 0;
  if (!semFd) printf("  (this Vulkan driver cannot share semaphores; frames are finished before each present)\n");
  const char* exts[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME};
  VkPhysicalDeviceVulkan12Features f12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
  f12.timelineSemaphore = VK_TRUE;
  VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  dci.pNext = &f12;
  dci.queueCreateInfoCount = 1;
  dci.pQueueCreateInfos = &q;
  dci.enabledExtensionCount = semFd ? 2 : 1;
  dci.ppEnabledExtensionNames = exts;
  VkDevice dev;
  CHECK(vkCreateDevice(phys, &dci, nullptr, &dev));
  VkQueue queue;
  vkGetDeviceQueue(dev, 0, 0, &queue);
  auto getMemFd = (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdKHR");
  auto getSemFd = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(dev, "vkGetSemaphoreFdKHR");

  VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
  ci.imageType = VK_IMAGE_TYPE_2D;
  ci.format = format;
  ci.extent = {W, H, 1};
  ci.mipLevels = 1;
  ci.arrayLayers = 1;
  ci.samples = VK_SAMPLE_COUNT_1_BIT;
  ci.tiling = VK_IMAGE_TILING_OPTIMAL;
  ci.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
  VkPhysicalDeviceMemoryProperties mp;
  vkGetPhysicalDeviceMemoryProperties(phys, &mp);
  VkPhysicalDeviceIDProperties idp{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
  VkPhysicalDeviceProperties2 p2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
  p2.pNext = &idp;
  vkGetPhysicalDeviceProperties2(phys, &p2);

  init_packet init{};
  init.num_images = 3;
  memcpy(init.device_uuid.data(), idp.deviceUUID, VK_UUID_SIZE);
  init.image_create_info = ci;
  init.source_pid = getpid();
  std::vector<int> fds;
  VkImage images[3];
  VkSemaphore sems[3];
  for (int i = 0; i < 3; i++) {
    VkExternalMemoryImageCreateInfo ext{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkImageCreateInfo c = ci;
    c.pNext = &ext;
    CHECK(vkCreateImage(dev, &c, nullptr, &images[i]));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(dev, images[i], &req);
    uint32_t type = 0;
    while (!((req.memoryTypeBits >> type) & 1) ||
           !(mp.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
      type++;
    init.mem_index = type;
    VkExportMemoryAllocateInfo exp{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};
    exp.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkMemoryDedicatedAllocateInfo ded{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    ded.image = images[i];
    ded.pNext = &exp;
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    mai.pNext = &ded;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = type;
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &mai, nullptr, &mem));
    CHECK(vkBindImageMemory(dev, images[i], mem, 0));
    VkMemoryGetFdInfoKHR gfd{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};
    gfd.memory = mem;
    gfd.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    int fd;
    CHECK(getMemFd(dev, &gfd, &fd));
    fds.push_back(fd);
    if (!semFd) {  // placeholder fd so the message layout matches the capture layer's
      fds.push_back(dup(fds.back()));
      sems[i] = VK_NULL_HANDLE;
      continue;
    }
    VkExportSemaphoreCreateInfo es{VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO};
    es.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkSemaphoreTypeCreateInfo tl{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    tl.pNext = &es;
    tl.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    VkSemaphoreCreateInfo sci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    sci.pNext = &tl;
    CHECK(vkCreateSemaphore(dev, &sci, nullptr, &sems[i]));
    VkSemaphoreGetFdInfoKHR sfd{VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR};
    sfd.semaphore = sems[i];
    sfd.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    CHECK(getSemFd(dev, &sfd, &fd));
    fds.push_back(fd);
  }

  // Staging buffer with the frame pattern.
  VkBufferCreateInfo bci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
  bci.size = W * H * 4;
  bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
  VkBuffer staging;
  CHECK(vkCreateBuffer(dev, &bci, nullptr, &staging));
  VkMemoryRequirements breq;
  vkGetBufferMemoryRequirements(dev, staging, &breq);
  uint32_t btype = 0;
  while (!((breq.memoryTypeBits >> btype) & 1) ||
         !(mp.memoryTypes[btype].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
    btype++;
  VkMemoryAllocateInfo bmai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
  bmai.allocationSize = breq.size;
  bmai.memoryTypeIndex = btype;
  VkDeviceMemory bmem;
  CHECK(vkAllocateMemory(dev, &bmai, nullptr, &bmem));
  CHECK(vkBindBufferMemory(dev, staging, bmem, 0));
  uint8_t* px;
  CHECK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void**)&px));
  VkCommandPoolCreateInfo cpi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
  cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  VkCommandPool pool;
  CHECK(vkCreateCommandPool(dev, &cpi, nullptr, &pool));
  VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  cai.commandPool = pool;
  cai.commandBufferCount = 1;
  VkCommandBuffer cmd;
  CHECK(vkAllocateCommandBuffers(dev, &cai, &cmd));

  int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sock.c_str(), sizeof addr.sun_path - 1);
  for (int t = 0; connect(s, (sockaddr*)&addr, sizeof addr) != 0; t++) {
    if (t > 100) return 3;
    usleep(50000);
  }
  if (write(s, &init, sizeof init) != sizeof init) return 4;
  {
    char data[1] = {0};
    iovec iov{data, 1};
    char ctrl[CMSG_SPACE(sizeof(int) * 6)] = {};
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl;
    msg.msg_controllen = sizeof ctrl;
    cmsghdr* c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int) * 6);
    memcpy(CMSG_DATA(c), fds.data(), sizeof(int) * 6);
    if (sendmsg(s, &msg, 0) < 0) return 5;
  }
  uint64_t values[3] = {0, 0, 0};
  for (int f = 0; f < kFrames; f++) {
    int i = f % 3;
    uint8_t a[3], b[3];
    ColorsFor(f, a, b);
    for (uint32_t y = 0; y < H; y++)
      for (uint32_t x = 0; x < W; x++) {
        const uint8_t* c = x < W / 2 ? a : b;
        uint8_t* p = px + (y * W + x) * 4;
        bool bgra = format == VK_FORMAT_B8G8R8A8_SRGB || format == VK_FORMAT_B8G8R8A8_UNORM;
        p[0] = bgra ? c[2] : c[0];
        p[1] = c[1];
        p[2] = bgra ? c[0] : c[2];
        p[3] = 255;
      }
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    vkResetCommandBuffer(cmd, 0);
    vkBeginCommandBuffer(cmd, &bi);
    VkImageMemoryBarrier ib{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    ib.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    ib.srcQueueFamilyIndex = ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    ib.image = images[i];
    ib.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &ib);
    VkBufferImageCopy region{};
    region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    region.imageExtent = {W, H, 1};
    vkCmdCopyBufferToImage(cmd, staging, images[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    ib.dstAccessMask = 0;
    ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    ib.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &ib);
    vkEndCommandBuffer(cmd);
    uint64_t v = ++values[i];
    VkTimelineSemaphoreSubmitInfo ts{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    ts.signalSemaphoreValueCount = 1;
    ts.pSignalSemaphoreValues = &v;
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.pNext = &ts;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    si.signalSemaphoreCount = sems[i] ? 1 : 0;
    si.pSignalSemaphores = &sems[i];
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));
    present_packet p{};
    p.image = i;
    p.frame = f;
    p.semaphore_value = v;
    for (int r = 0; r < 3; r++) p.pose[r][r] = 1;
    p.pose[0][3] = float(f);  // lets the test check the pose was passed through
    if (write(s, &p, sizeof p) != sizeof p) return 6;
    usleep(1000000 / 30);
  }
  usleep(1500000);
  close(s);
  return 0;
}

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : "/tmp";
  setenv("XDG_RUNTIME_DIR", dir.c_str(), 1);
  setenv("LOCALVIEW_VR_STDERR", "1", 1);
  setenv("LOCALVIEW_VR_TEST", "1", 1);
  const std::string out = dir + "/lv_test.h264";
  int failures = 0;
  for (VkFormat format : {VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM}) {
    std::mutex m;
    std::vector<uint8_t> stream;
    int frames = 0, keys = 0;
    std::vector<float> poses;
    LinuxStreamer streamer;
    std::vector<float> recorded;
    bool ok = streamer.Start(
        W, H, 30, 8,
        [&](const vr::HmdMatrix34_t& pose) {
          std::lock_guard<std::mutex> l(m);
          recorded.push_back(pose.m[0][3]);
          return uint64_t(recorded.size());
        },
        [&](const uint8_t* d, size_t n, bool key, uint64_t user) {
          std::lock_guard<std::mutex> l(m);
          stream.insert(stream.end(), d, d + n);
          frames++;
          keys += key;
          poses.push_back(user ? recorded[user - 1] : -1.f);
          if (getenv("LV_TEST_VERBOSE")) {
            std::string nals;
            for (size_t i = 0; i + 3 < n; i++)
              if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) nals += std::to_string(d[i + 3] & 0x1f) + ",";
            printf("  AU user=%llu bytes=%zu nals=%s\n", (unsigned long long)user, n, nals.c_str());
          }
        });
    if (!ok) {
      fprintf(stderr, "streamer did not start\n");
      return 1;
    }
    pid_t pid = fork();
    if (pid == 0) _exit(FakeCompositor(dir + "/localview-vr-ipc", format));
    int status = 0;
    waitpid(pid, &status, 0);
    streamer.Stop();
    printf("format %d: compositor exit %d, %d frames encoded, %d keyframes, %zu bytes\n", int(format),
           WEXITSTATUS(status), frames, keys, stream.size());
    if (getenv("LV_TEST_VERBOSE")) {
      printf("  recorded:");
      for (float r : recorded) printf(" %g", r);
      printf("\n  emitted:");
      for (float r : poses) printf(" %g", r);
      printf("\n");
    }
    bool inOrder = true;
    for (size_t i = 1; i < poses.size(); i++)
      if (poses[i] <= poses[i - 1]) inOrder = false;
    if (WEXITSTATUS(status) != 0 || frames < kFrames / 2 || keys < 1 || !inOrder) {
      printf("  FAIL (poses in order: %d)\n", int(inOrder));
      failures++;
      continue;
    }
    // Decode the last frame and compare both eyes' colours with what was sent for its pose.
    std::ofstream(out, std::ios::binary).write((const char*)stream.data(), long(stream.size()));
    int lastFrame = int(poses.back());
    std::string rgb = dir + "/lv_test.rgb";
    std::string cmd = "ffmpeg -loglevel error -y -i " + out + " -vf 'select=eq(n\\," + std::to_string(frames - 1) +
                      ")' -frames:v 1 -f rawvideo -pix_fmt rgb24 " + rgb;
    if (system(cmd.c_str()) != 0) {
      printf("  FAIL: ffmpeg could not decode the stream\n");
      failures++;
      continue;
    }
    std::ifstream f(rgb, std::ios::binary);
    std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), {});
    if (img.size() != W * H * 3) {
      printf("  FAIL: decoded %zu bytes\n", img.size());
      failures++;
      continue;
    }
    uint8_t a[3], b[3];
    ColorsFor(lastFrame, a, b);
    auto at = [&](uint32_t x, uint32_t y) { return &img[(y * W + x) * 3]; };
    int err = 0;
    for (int c = 0; c < 3; c++) {
      err = std::max(err, std::abs(int(at(W / 4, H / 2)[c]) - int(a[c])));
      err = std::max(err, std::abs(int(at(3 * W / 4, H / 2)[c]) - int(b[c])));
    }
    printf("  last frame %d: left %d,%d,%d (want %d,%d,%d) right %d,%d,%d (want %d,%d,%d) max error %d\n", lastFrame,
           at(W / 4, H / 2)[0], at(W / 4, H / 2)[1], at(W / 4, H / 2)[2], a[0], a[1], a[2], at(3 * W / 4, H / 2)[0],
           at(3 * W / 4, H / 2)[1], at(3 * W / 4, H / 2)[2], b[0], b[1], b[2], err);
    if (err > 12) {
      printf("  FAIL: colours differ\n");
      failures++;
    }
  }
  printf(failures ? "FAILED\n" : "PASSED\n");
  return failures ? 1 : 0;
}
