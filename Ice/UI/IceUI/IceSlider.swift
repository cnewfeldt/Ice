//
//  IceSlider.swift
//  Ice
//

import SwiftUI

struct IceSlider<Value: BinaryFloatingPoint, ValueLabel: View>: View where Value.Stride: BinaryFloatingPoint {
    @Binding private var value: Value

    private let bounds: ClosedRange<Value>
    private let step: Value?
    private let valueLabel: ValueLabel

    @State private var isHovering = false
    @State private var isDragging = false

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value? = nil,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self._value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value? = nil
    ) where ValueLabel == Text {
        self._value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = Text(valueLabelKey)
    }

    private var borderShape: some InsettableShape {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .circular)
        }
    }

    private var height: CGFloat {
        if #available(macOS 26.0, *) { 24 } else { 22 }
    }

    private var fraction: CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else {
            return 0
        }
        return CGFloat((value.clamped(to: bounds) - bounds.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                borderShape
                    .fill(.primary.opacity(isHovering || isDragging ? 0.1 : 0.075))
                Rectangle()
                    .fill(Color.accentColor.opacity(isDragging ? 0.75 : 0.5))
                    .frame(width: geometry.size.width * fraction)
                valueLabel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 6)
            }
            .contentShape(borderShape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        updateValue(x: gesture.location.x, width: geometry.size.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: height)
        .clipShape(borderShape)
        .contentShape([.interaction, .focusEffect], borderShape)
        .onHover { isHovering = $0 }
        .accessibilityRepresentation {
            Slider(value: $value, in: bounds) { valueLabel }
        }
    }

    private func updateValue(x: CGFloat, width: CGFloat) {
        guard width > 0 else {
            return
        }
        let fraction = Value(min(max(x / width, 0), 1))
        var newValue = bounds.lowerBound + fraction * (bounds.upperBound - bounds.lowerBound)
        if let step, step > 0 {
            newValue = bounds.lowerBound + ((newValue - bounds.lowerBound) / step).rounded() * step
        }
        value = newValue.clamped(to: bounds)
    }
}
