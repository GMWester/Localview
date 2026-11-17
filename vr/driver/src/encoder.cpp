#include "encoder.h"

#include <mferror.h>
#include <initguid.h>
#include <codecapi.h>

#include "common.h"

using Microsoft::WRL::ComPtr;

namespace {
constexpr int kSlots = 4;
// {901db4c7-31ce-41a2-85dc-8fa0bf41b8da}
const GUID kIID_ICodecAPI = {0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};

void SetU32(ICodecAPI* c, const GUID& g, UINT32 v) {
  VARIANT var;
  VariantInit(&var);
  var.vt = VT_UI4;
  var.ulVal = v;
  c->SetValue(&g, &var);
}
void SetBool(ICodecAPI* c, const GUID& g, bool v) {
  VARIANT var;
  VariantInit(&var);
  var.vt = VT_BOOL;
  var.boolVal = v ? VARIANT_TRUE : VARIANT_FALSE;
  c->SetValue(&g, &var);
}
bool HasSps(const uint8_t* d, size_t n) {
  for (size_t i = 0; i + 4 < n && i < 256; i++) {
    if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && (d[i + 3] & 0x1f) == 7) return true;
  }
  return false;
}
}  // namespace

bool Encoder::Init(ID3D11Device* device, uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, Output out) {
  device_ = device;
  width_ = width;
  height_ = height;
  fps_ = fps;
  bitrate_ = bitrateMbps * 1000000u;
  out_ = std::move(out);
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) return false;

  ComPtr<ID3D10Multithread> mt;
  if (SUCCEEDED(device_.As(&mt))) mt->SetMultithreadProtected(TRUE);
  if (FAILED(MFCreateDXGIDeviceManager(&resetToken_, &manager_))) return false;
  if (FAILED(manager_->ResetDevice(device_.Get(), resetToken_))) return false;

  MFT_REGISTER_TYPE_INFO inInfo = {MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO outInfo = {MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** acts = nullptr;
  UINT32 count = 0;
  MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &inInfo, &outInfo, &acts, &count);
  // Use the encoder that belongs to our GPU when several adapters expose one.
  for (UINT32 i = 0; i < count && !mft_; i++) {
    ComPtr<IMFTransform> t;
    if (FAILED(acts[i]->ActivateObject(IID_PPV_ARGS(&t)))) continue;
    ComPtr<IMFAttributes> attrs;
    if (FAILED(t->GetAttributes(&attrs))) continue;
    attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
    attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
    if (FAILED(t->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(manager_.Get())))) continue;
    mft_ = t;
    WCHAR name[128] = L"?";
    UINT32 len = 0;
    acts[i]->GetString(MFT_FRIENDLY_NAME_Attribute, name, 128, &len);
    LvLog("using hardware encoder: %ls", name);
  }
  for (UINT32 i = 0; i < count; i++) acts[i]->Release();
  CoTaskMemFree(acts);
  if (!mft_) {
    LvLog("no hardware H.264 encoder found");
    return false;
  }
  if (!Configure()) return false;

  D3D11_TEXTURE2D_DESC td = {};
  td.Width = width_;
  td.Height = height_;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_NV12;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  for (int i = 0; i < kSlots; i++) {
    ComPtr<ID3D11Texture2D> t;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &t))) return false;
    slots_.push_back(t);
  }
  mft_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  running_ = true;
  thread_ = std::thread([this] { Loop(); });
  return true;
}

bool Encoder::Configure() {
  ComPtr<IMFMediaType> outType;
  MFCreateMediaType(&outType);
  outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  outType->SetUINT32(MF_MT_AVG_BITRATE, bitrate_);
  MFSetAttributeSize(outType.Get(), MF_MT_FRAME_SIZE, width_, height_);
  MFSetAttributeRatio(outType.Get(), MF_MT_FRAME_RATE, UINT32(fps_ * 1000), 1000);
  MFSetAttributeRatio(outType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  outType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  outType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
  outType->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  outType->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
  HRESULT hr = mft_->SetOutputType(0, outType.Get(), 0);
  if (FAILED(hr)) {
    outType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
    hr = mft_->SetOutputType(0, outType.Get(), 0);
  }
  if (FAILED(hr)) {
    LvLog("encoder rejected output type %ux%u (0x%08x)", width_, height_, hr);
    return false;
  }
  ComPtr<IMFMediaType> inType;
  MFCreateMediaType(&inType);
  inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(inType.Get(), MF_MT_FRAME_SIZE, width_, height_);
  MFSetAttributeRatio(inType.Get(), MF_MT_FRAME_RATE, UINT32(fps_ * 1000), 1000);
  inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  hr = mft_->SetInputType(0, inType.Get(), 0);
  if (FAILED(hr)) {
    LvLog("encoder rejected NV12 input (0x%08x)", hr);
    return false;
  }
  if (SUCCEEDED(mft_->QueryInterface(kIID_ICodecAPI, reinterpret_cast<void**>(codec_.ReleaseAndGetAddressOf())))) {
    SetBool(codec_.Get(), CODECAPI_AVLowLatencyMode, true);
    SetU32(codec_.Get(), CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_CBR);
    SetU32(codec_.Get(), CODECAPI_AVEncCommonMeanBitRate, bitrate_);
    SetU32(codec_.Get(), CODECAPI_AVEncMPVGOPSize, UINT32(fps_ * 10));
    SetU32(codec_.Get(), CODECAPI_AVEncMPVDefaultBPictureCount, 0);
  }
  ComPtr<IMFMediaType> cur;
  if (SUCCEEDED(mft_->GetOutputCurrentType(0, &cur))) {
    UINT32 sz = 0;
    if (SUCCEEDED(cur->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &sz)) && sz > 0) {
      sequenceHeader_.resize(sz);
      cur->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, sequenceHeader_.data(), sz, nullptr);
    }
  }
  return SUCCEEDED(mft_.As(&events_));
}

bool Encoder::Submit(ID3D11DeviceContext* ctx, ID3D11Texture2D* nv12, uint64_t userData) {
  std::lock_guard<std::mutex> l(mutex_);
  if (!running_ || queued_.size() + inFlight_.size() >= kSlots - 1) return false;  // behind: drop
  int slot = nextSlot_;
  nextSlot_ = (nextSlot_ + 1) % kSlots;
  ctx->CopyResource(slots_[slot].Get(), nv12);
  ctx->Flush();
  queued_.push_back({slot, userData});
  if (needInput_ > 0) FeedOne();
  return true;
}

// Requires mutex_.
bool Encoder::FeedOne() {
  if (queued_.empty() || needInput_ <= 0) return false;
  auto [slot, user] = queued_.front();
  queued_.pop_front();
  ComPtr<IMFMediaBuffer> buf;
  if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), slots_[slot].Get(), 0, FALSE, &buf))) return false;
  ComPtr<IMF2DBuffer> b2;
  if (SUCCEEDED(buf.As(&b2))) {
    DWORD len = 0;
    b2->GetContiguousLength(&len);
    buf->SetCurrentLength(len);
  }
  ComPtr<IMFSample> sample;
  MFCreateSample(&sample);
  sample->AddBuffer(buf.Get());
  const int64_t dur = int64_t(10000000.0 / fps_);
  sample->SetSampleTime(sampleTime_);
  sample->SetSampleDuration(dur);
  sampleTime_ += dur;
  if (forceKey_.exchange(false) && codec_) SetU32(codec_.Get(), CODECAPI_AVEncVideoForceKeyFrame, 1);
  HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
  if (FAILED(hr)) {
    LvLog("ProcessInput failed 0x%08x", hr);
    return false;
  }
  needInput_--;
  inFlight_.push_back(user);
  return true;
}

void Encoder::DrainOne() {
  MFT_OUTPUT_STREAM_INFO info = {};
  mft_->GetOutputStreamInfo(0, &info);
  MFT_OUTPUT_DATA_BUFFER od = {};
  ComPtr<IMFSample> own;
  if (!(info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES))) {
    ComPtr<IMFMediaBuffer> b;
    MFCreateMemoryBuffer(info.cbSize ? info.cbSize : (width_ * height_), &b);
    MFCreateSample(&own);
    own->AddBuffer(b.Get());
    od.pSample = own.Get();
  }
  DWORD status = 0;
  HRESULT hr = mft_->ProcessOutput(0, 1, &od, &status);
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    ComPtr<IMFMediaType> t;
    if (SUCCEEDED(mft_->GetOutputAvailableType(0, 0, &t))) mft_->SetOutputType(0, t.Get(), 0);
    if (od.pEvents) od.pEvents->Release();
    return;
  }
  if (od.pEvents) od.pEvents->Release();
  if (FAILED(hr) || !od.pSample) return;
  ComPtr<IMFSample> sample = od.pSample;
  if (!own) od.pSample->Release();
  uint64_t user = 0;
  {
    std::lock_guard<std::mutex> l(mutex_);
    if (!inFlight_.empty()) {
      user = inFlight_.front();
      inFlight_.pop_front();
    }
  }
  UINT32 clean = 0;
  sample->GetUINT32(MFSampleExtension_CleanPoint, &clean);
  ComPtr<IMFMediaBuffer> buf;
  if (FAILED(sample->ConvertToContiguousBuffer(&buf))) return;
  BYTE* data = nullptr;
  DWORD len = 0;
  if (FAILED(buf->Lock(&data, nullptr, &len))) return;
  if (clean && !sequenceHeader_.empty() && !HasSps(data, len)) {
    std::vector<uint8_t> joined(sequenceHeader_);
    joined.insert(joined.end(), data, data + len);
    out_(joined.data(), joined.size(), true, user);
  } else {
    out_(data, len, clean != 0, user);
  }
  buf->Unlock();
}

void Encoder::Loop() {
  while (running_) {
    ComPtr<IMFMediaEvent> ev;
    HRESULT hr = events_->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev);
    if (hr == MF_E_NO_EVENTS_AVAILABLE) {
      Sleep(1);
      continue;
    }
    if (FAILED(hr)) {
      Sleep(5);
      continue;
    }
    MediaEventType type = MEUnknown;
    ev->GetType(&type);
    if (type == METransformNeedInput) {
      std::lock_guard<std::mutex> l(mutex_);
      needInput_++;
      FeedOne();
    } else if (type == METransformHaveOutput) {
      DrainOne();
    }
  }
}

void Encoder::Shutdown() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  if (mft_) {
    mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    mft_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  }
  mft_.Reset();
  events_.Reset();
  codec_.Reset();
  slots_.clear();
  if (manager_) manager_.Reset();
  MFShutdown();
}
