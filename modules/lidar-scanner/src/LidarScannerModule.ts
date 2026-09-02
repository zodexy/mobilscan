import { NativeModule, requireNativeModule } from 'expo';

declare class LidarScannerModule extends NativeModule<{}> {
  clearData(): Promise<void>;
  getLatestScanDir(): Promise<string | null>;
}

export default requireNativeModule<LidarScannerModule>('LidarScanner');
