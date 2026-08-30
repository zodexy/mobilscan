import { NativeModule, requireNativeModule } from 'expo';

declare class LidarScannerModule extends NativeModule<{}> {
  clearData(): Promise<void>;
}

export default requireNativeModule<LidarScannerModule>('LidarScanner');
