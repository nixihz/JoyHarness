import SwiftUI

/// Reference gestures and parameter edits stay in a draft until the user applies them.
struct MotionJumpSettingsView: View {
    @ObservedObject var coordinator: MotionJumpCoordinator
    @ObservedObject var settings: MotionJumpSettings
    @State private var showsAdvancedParameters = false
    @State private var confirmsClearCalibration = false

    var body: some View {
        Section {
            Text(L10n.text(
                "按住 L2，轻转手腕朝向一个角，松开后定位到该屏幕分区中心，再用摇杆或触控板微调。",
                "Hold L2 and gently turn your wrist toward a corner. Release to jump to that quadrant’s center, then fine-tune with the stick or touchpad."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(L10n.text("启用体感快速定位", "Enable Motion Jump"), isOn: $settings.enabled)
                .disabled(settings.profile == nil || coordinator.phase != .idle)

            Text(settings.profile == nil
                 ? L10n.text("四个方向各录一次，再应用校准即可启用。测试可随时选做。", "Record each direction once, then apply calibration to enable it. Testing is optional.")
                 : L10n.text("当前使用已保存的个人校准。", "Using your saved personal calibration."))
                .font(.caption)
                .foregroundStyle(.secondary)

            devicePicker
            sessionActions

            if coordinator.phase != .idle || !coordinator.statusText.isEmpty {
                sessionStatus
            }

            quadrantPreview

            if hasRecordedReferences {
                referenceActions
            }

            if !coordinator.lastResultText.isEmpty {
                Text(coordinator.lastResultText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let parameters = editableParameters {
                advancedParameters(parameters)
            }

            if coordinator.phase == .testing {
                Toggle(
                    L10n.text("测试实际定位", "Test Actual Pointer Movement"),
                    isOn: $coordinator.isTestingActualPointer
                )
                .disabled(coordinator.isTestComplete)
                Text(coordinator.isTestComplete
                     ? L10n.text("如需测试实际定位，请先点击“重新测试”，再开启此选项。", "To test actual pointer movement, choose Restart Test, then enable this option.")
                     : coordinator.isTestingActualPointer
                        ? L10n.text("测试会移动系统光标。点击“结束测试”退出。", "Testing moves the system pointer. Choose End Test to exit.")
                        : L10n.text("仅在上方预览区显示结果，系统光标保持原位。", "Results appear in the preview above; the system pointer stays in place."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !coordinator.validationSummary.isEmpty {
                Text(coordinator.validationSummary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.draft != nil {
                HStack {
                    Button(L10n.text("应用校准", "Apply Calibration")) {
                        coordinator.applyCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.canApply)

                    Text(L10n.text("保存为个人默认", "Save as your personal default"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.text(
                    "测试帮助你了解手感，不要求全部命中。点击应用才保存，之前的配置会保留到应用时。",
                    "Testing helps you judge the feel; every trial need not match. Your saved settings stay active until you apply this draft."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if coordinator.phase == .idle {
                    Button(L10n.text("撤回本次调整", "Discard These Adjustments")) {
                        coordinator.stopSession()
                    }
                }
            }

            if settings.profile != nil {
                restoreActions
            }
        } header: {
            Text(L10n.text("体感快速定位", "Motion Jump"))
        }
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.text("校准设备", "Calibration Device"), selection: $coordinator.selectedDeviceID) {
                Text(L10n.text("选择 DualSense", "Select a DualSense"))
                    .tag(nil as String?)
                ForEach(coordinator.devices, id: \.id) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(coordinator.phase != .idle || coordinator.devices.isEmpty)

            if coordinator.devices.isEmpty {
                Text(L10n.text(
                    "连接支持体感的 DualSense 手柄后，即可开始录制。",
                    "Connect a DualSense controller with motion support to start recording."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sessionActions: some View {
        switch coordinator.phase {
        case .idle:
            HStack(spacing: 8) {
                Button(hasRecordedReferences
                       ? L10n.text("全部重新录制", "Record All Again")
                       : L10n.text("录制我的手势", "Record My Gestures")) {
                    coordinator.startCalibration()
                }
                .disabled(coordinator.selectedDeviceID == nil)

                Button(L10n.text("测试", "Test")) {
                    coordinator.startTesting()
                }
                .disabled(coordinator.selectedDeviceID == nil || editableParameters == nil)
            }
        case .recording:
            Button(L10n.text("取消录制", "Cancel Recording")) {
                coordinator.cancelRecording()
            }
        case .testing:
            HStack(spacing: 8) {
                Button(L10n.text("重新测试", "Restart Test")) {
                    coordinator.startTesting()
                }
                Button(L10n.text("结束测试", "End Test")) {
                    coordinator.endTesting()
                }
            }
        }
    }

    private var sessionStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !coordinator.statusText.isEmpty {
                Text(coordinator.statusText)
                    .font(.callout)
            }
            if !coordinator.progressText.isEmpty {
                Text(coordinator.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if coordinator.phase == .recording {
                Text(L10n.text(
                    "普通 L2 按放与四个方向各录一次。大致朝目标方向转动即可，不必精确到某个角度；完全松开 L2 完成一次。录制只用传感器，无需摄像头。",
                    "Record one ordinary L2 press and each direction once. Turn roughly toward the target; no precise angle is needed. Release L2 fully to finish. Recording uses sensors, not a camera."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var hasRecordedReferences: Bool {
        coordinator.hasOrdinarySample || !coordinator.recordedQuadrants.isEmpty
    }

    private var referenceActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("某个方向不顺手，只需单独重录；其他参考会保留。", "If one direction feels awkward, re-record only that gesture. The other references stay saved in this draft."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                referenceButton(.upperLeft)
                referenceButton(.upperRight)
            }
            HStack(spacing: 8) {
                referenceButton(.lowerLeft)
                referenceButton(.lowerRight)
            }
            Button(coordinator.hasOrdinarySample
                   ? L10n.text("重录普通 L2 按放", "Re-record Ordinary L2 Press")
                   : L10n.text("录制普通 L2 按放", "Record Ordinary L2 Press")) {
                coordinator.rerecordGesture(nil)
            }
        }
        .disabled(coordinator.phase == .recording || coordinator.selectedDeviceID == nil)
    }

    private func referenceButton(_ quadrant: MotionJumpQuadrant) -> some View {
        let recorded = coordinator.recordedQuadrants.contains(quadrant)
        return Button {
            coordinator.rerecordGesture(quadrant)
        } label: {
            Label(recorded
                  ? L10n.text("重录\(quadrantTitle(quadrant))", "Re-record \(quadrantTitle(quadrant))")
                  : L10n.text("录制\(quadrantTitle(quadrant))", "Record \(quadrantTitle(quadrant))"),
                  systemImage: recorded ? "checkmark.circle" : "circle")
        }
    }

    private var quadrantPreview: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                quadrantCell(.upperLeft, arrow: "arrow.up.left")
                quadrantCell(.upperRight, arrow: "arrow.up.right")
            }
            HStack(spacing: 4) {
                quadrantCell(.lowerLeft, arrow: "arrow.down.left")
                quadrantCell(.lowerRight, arrow: "arrow.down.right")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("四分区定位预览", "Screen Quadrant Preview"))
        .accessibilityValue(coordinator.previewQuadrant.map(quadrantTitle)
            ?? L10n.text("尚未识别到方向", "No direction recognized yet"))
    }

    private func quadrantCell(_ quadrant: MotionJumpQuadrant, arrow: String) -> some View {
        let selected = coordinator.previewQuadrant == quadrant
        return HStack(spacing: 4) {
            Image(systemName: selected ? "checkmark.circle.fill" : arrow)
            Text(quadrantTitle(quadrant))
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.secondary, lineWidth: 1)
        }
    }

    private func quadrantTitle(_ quadrant: MotionJumpQuadrant) -> String {
        switch quadrant {
        case .upperLeft: return L10n.text("左上", "Upper Left")
        case .upperRight: return L10n.text("右上", "Upper Right")
        case .lowerLeft: return L10n.text("左下", "Lower Left")
        case .lowerRight: return L10n.text("右下", "Lower Right")
        }
    }

    private var editableParameters: MotionJumpParameters? {
        if hasRecordedReferences && coordinator.draft == nil { return nil }
        return coordinator.draft?.parameters ?? settings.profile?.parameters
    }

    private func advancedParameters(_ parameters: MotionJumpParameters) -> some View {
        DisclosureGroup(L10n.text("调整手势阈值", "Adjust Gesture Thresholds"), isExpanded: $showsAdvancedParameters) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(
                    "先录制生成适合自己的参数，再小幅调整。幅度和速度越低越容易触发；方向容差越大越宽松。",
                    "Start with your recorded calibration, then make small adjustments. Lower angle and speed thresholds trigger more easily; larger direction tolerance is more permissive."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                parameterSlider(
                    L10n.text("最小动作幅度", "Minimum Angle"),
                    keyPath: \.minimumAngle,
                    range: MotionJumpParameters.minimumAngleRange,
                    valueText: String(format: "%.1f°", parameters.minimumAngle * 180 / .pi)
                )
                parameterSlider(
                    L10n.text("最小动作速度", "Minimum Peak Speed"),
                    keyPath: \.minimumPeakSpeed,
                    range: MotionJumpParameters.minimumPeakSpeedRange,
                    valueText: String(format: "%.0f°/s", parameters.minimumPeakSpeed * 180 / .pi)
                )
                parameterSlider(
                    L10n.text("最长动作时间", "Maximum Duration"),
                    keyPath: \.maximumDuration,
                    range: MotionJumpParameters.maximumDurationRange,
                    valueText: String(format: "%.1f s", parameters.maximumDuration)
                )
                parameterSlider(
                    L10n.text("方向容差", "Direction Tolerance"),
                    keyPath: \.directionTolerance,
                    range: MotionJumpParameters.directionToleranceRange,
                    valueText: String(format: "%.0f°", parameters.directionTolerance)
                )
            }
            .padding(.top, 8)
            .disabled(coordinator.phase == .recording)
        }
    }

    private func parameterSlider(
        _ title: String,
        keyPath: WritableKeyPath<MotionJumpParameters, Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: Binding(
                get: { editableParameters?[keyPath: keyPath] ?? range.lowerBound },
                set: { value in
                    guard var parameters = editableParameters else { return }
                    parameters[keyPath: keyPath] = value
                    coordinator.updateParameters(parameters)
                }
            ), in: range)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
        }
    }

    private var restoreActions: some View {
        Menu(L10n.text("恢复校准", "Restore Calibration")) {
            if settings.canRestorePreviousCalibration {
                Button(L10n.text("恢复上次校准", "Restore Previous Calibration")) {
                    coordinator.restorePreviousCalibration()
                }
            }
            Button(L10n.text("清除校准并停用", "Clear Calibration and Disable"), role: .destructive) {
                confirmsClearCalibration = true
            }
        }
        .disabled(coordinator.phase != .idle)
        .confirmationDialog(L10n.text("清除全部个人校准？", "Clear All Personal Calibration?"),
                            isPresented: $confirmsClearCalibration) {
            Button(L10n.text("清除校准并停用", "Clear Calibration and Disable"), role: .destructive) {
                coordinator.clearCalibration()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("当前及上次校准都会被删除，需要重新录制才能使用体感快速定位。",
                           "Current and previous calibrations will be deleted. Record again to use Motion Jump."))
        }
    }
}
