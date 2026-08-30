import { requireNativeView } from 'expo';
import * as React from 'react';
import { ViewProps } from 'react-native';

export type LidarScannerViewProps = {
  isScanning?: boolean;
  onFrameCaptured?: (event: { nativeEvent: { frameCount: number } }) => void;
} & ViewProps;

const NativeView = requireNativeView<LidarScannerViewProps>('LidarScanner');

export default function LidarScannerView(props: LidarScannerViewProps) {
  return <NativeView {...props} />;
}
