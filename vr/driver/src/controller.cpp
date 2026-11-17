#include <cmath>

#include "devices.h"

vr::EVRInitError Controller::Activate(uint32_t id) {
  id_ = id;
  auto props = vr::VRProperties();
  container_ = props->TrackedDeviceToPropertyContainer(id);
  const bool left = hand_ == 0;
  // Presented to SteamVR as Oculus Touch controllers so games ship working bindings.
  props->SetStringProperty(container_, vr::Prop_TrackingSystemName_String, "oculus");
  props->SetStringProperty(container_, vr::Prop_ManufacturerName_String, "Oculus");
  props->SetStringProperty(container_, vr::Prop_ModelNumber_String,
                           left ? "Oculus Quest2 (Left Controller)" : "Oculus Quest2 (Right Controller)");
  props->SetStringProperty(container_, vr::Prop_RenderModelName_String,
                           left ? "oculus_quest2_controller_left" : "oculus_quest2_controller_right");
  props->SetStringProperty(container_, vr::Prop_SerialNumber_String, Serial());
  props->SetStringProperty(container_, vr::Prop_ControllerType_String, "oculus_touch");
  props->SetStringProperty(container_, vr::Prop_InputProfilePath_String, "{oculus}/input/touch_profile.json");
  props->SetInt32Property(container_, vr::Prop_ControllerRoleHint_Int32,
                          left ? vr::TrackedControllerRole_LeftHand : vr::TrackedControllerRole_RightHand);
  props->SetInt32Property(container_, vr::Prop_ControllerHandSelectionPriority_Int32, 2147483647);

  auto in = vr::VRDriverInput();
  in->CreateBooleanComponent(container_, left ? "/input/x/click" : "/input/a/click", &bools_[kA]);
  in->CreateBooleanComponent(container_, left ? "/input/x/touch" : "/input/a/touch", &bools_[kATouch]);
  in->CreateBooleanComponent(container_, left ? "/input/y/click" : "/input/b/click", &bools_[kB]);
  in->CreateBooleanComponent(container_, left ? "/input/y/touch" : "/input/b/touch", &bools_[kBTouch]);
  in->CreateBooleanComponent(container_, "/input/system/click", &bools_[kSystem]);
  in->CreateBooleanComponent(container_, "/input/trigger/click", &bools_[kTrigClick]);
  in->CreateBooleanComponent(container_, "/input/trigger/touch", &bools_[kTrigTouch]);
  in->CreateBooleanComponent(container_, "/input/joystick/click", &bools_[kStickClick]);
  in->CreateBooleanComponent(container_, "/input/joystick/touch", &bools_[kStickTouch]);
  in->CreateBooleanComponent(container_, "/input/thumbrest/touch", &bools_[kThumbrest]);
  in->CreateBooleanComponent(container_, "/input/grip/touch", &bools_[kGripTouch]);
  in->CreateBooleanComponent(container_, "/input/grip/click", &bools_[kGripClick]);
  in->CreateScalarComponent(container_, "/input/trigger/value", &scalars_[kTrigValue], vr::VRScalarType_Absolute,
                            vr::VRScalarUnits_NormalizedOneSided);
  in->CreateScalarComponent(container_, "/input/grip/value", &scalars_[kGripValue], vr::VRScalarType_Absolute,
                            vr::VRScalarUnits_NormalizedOneSided);
  in->CreateScalarComponent(container_, "/input/joystick/x", &scalars_[kStickX], vr::VRScalarType_Absolute,
                            vr::VRScalarUnits_NormalizedTwoSided);
  in->CreateScalarComponent(container_, "/input/joystick/y", &scalars_[kStickY], vr::VRScalarType_Absolute,
                            vr::VRScalarUnits_NormalizedTwoSided);
  in->CreateHapticComponent(container_, "/output/haptic", &haptic_);
  pose_ = ToDriverPose({0, 0, 0, 0, 0, 0, 1}, nullptr, nullptr, false);
  return vr::VRInitError_None;
}

vr::DriverPose_t Controller::GetPose() {
  std::lock_guard<std::mutex> l(mutex_);
  return pose_;
}

void Controller::Disconnect() {
  std::lock_guard<std::mutex> l(mutex_);
  pose_.poseIsValid = false;
  pose_.result = vr::TrackingResult_Running_OutOfRange;
  if (id_ != vr::k_unTrackedDeviceIndexInvalid) vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id_, pose_, sizeof pose_);
}

void Controller::Update(const lvvr::ControllerState& s) {
  if (id_ == vr::k_unTrackedDeviceIndexInvalid) return;
  lvvr::Pose p = s.pose;
  if (pitchDeg_ != 0.f) {  // optional grip-pose correction: q * rotX(pitch)
    float h = pitchDeg_ * 3.14159265f / 360.f, sx = std::sin(h), cw = std::cos(h);
    lvvr::Pose q = p;
    p.qw = q.qw * cw - q.qx * sx;
    p.qx = q.qx * cw + q.qw * sx;
    p.qy = q.qy * cw + q.qz * sx;
    p.qz = q.qz * cw - q.qy * sx;
  }
  {
    std::lock_guard<std::mutex> l(mutex_);
    pose_ = ToDriverPose(p, s.linVel, s.angVel, s.active != 0);
    vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id_, pose_, sizeof pose_);
  }
  auto in = vr::VRDriverInput();
  const bool left = hand_ == 0;
  auto b = [&](uint32_t bit) { return (s.buttons & bit) != 0; };
  in->UpdateBooleanComponent(bools_[kA], b(left ? lvvr::kBtnX : lvvr::kBtnA), 0);
  in->UpdateBooleanComponent(bools_[kATouch], b(left ? lvvr::kBtnXTouch : lvvr::kBtnATouch), 0);
  in->UpdateBooleanComponent(bools_[kB], b(left ? lvvr::kBtnY : lvvr::kBtnB), 0);
  in->UpdateBooleanComponent(bools_[kBTouch], b(left ? lvvr::kBtnYTouch : lvvr::kBtnBTouch), 0);
  in->UpdateBooleanComponent(bools_[kSystem], b(lvvr::kBtnMenu) || b(lvvr::kBtnSystem), 0);
  in->UpdateBooleanComponent(bools_[kTrigClick], s.trigger > 0.85f, 0);
  in->UpdateBooleanComponent(bools_[kTrigTouch], b(lvvr::kBtnTriggerTouch) || s.trigger > 0.05f, 0);
  in->UpdateBooleanComponent(bools_[kStickClick], b(lvvr::kBtnStickClick), 0);
  in->UpdateBooleanComponent(bools_[kStickTouch], b(lvvr::kBtnStickTouch) || std::fabs(s.stickX) + std::fabs(s.stickY) > 0.05f, 0);
  in->UpdateBooleanComponent(bools_[kThumbrest], b(lvvr::kBtnThumbrestTouch), 0);
  in->UpdateBooleanComponent(bools_[kGripTouch], s.grip > 0.05f, 0);
  in->UpdateBooleanComponent(bools_[kGripClick], s.grip > 0.85f, 0);
  in->UpdateScalarComponent(scalars_[kTrigValue], s.trigger, 0);
  in->UpdateScalarComponent(scalars_[kGripValue], s.grip, 0);
  in->UpdateScalarComponent(scalars_[kStickX], s.stickX, 0);
  in->UpdateScalarComponent(scalars_[kStickY], s.stickY, 0);
}
