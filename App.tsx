import { StatusBar } from 'expo-status-bar';
import { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, SafeAreaView, Alert, ActivityIndicator } from 'react-native';
import * as FileSystem from 'expo-file-system';
import { zip } from 'react-native-zip-archive';
import LidarScannerView from './modules/lidar-scanner/src/LidarScannerView';
import LidarScannerModule from './modules/lidar-scanner/src/LidarScannerModule';

// TODO: Ide másold be a 'modal serve backend/modal_app.py' által generált URL-t!
// Például: const API_URL = 'https://te-neved--mobilscan-backend-fastapi-app-dev.modal.run';
const API_URL = 'https://zodexy--mobilscan-backend-fastapi-app.modal.run';

export default function App() {
  const [isScanning, setIsScanning] = useState(false);
  const [frameCount, setFrameCount] = useState(0);

  // Állapotok a feldolgozáshoz
  const [isProcessing, setIsProcessing] = useState(false);
  const [processStatus, setProcessStatus] = useState<string>('');
  const [completedJobId, setCompletedJobId] = useState<string | null>(null);

  const handleClearData = async () => {
    Alert.alert(
      "Adatok törlése",
      "Biztosan törölni szeretnéd az összes eddigi mentett szkennelést a telefonról?",
      [
        { text: "Mégsem", style: "cancel" },
        {
          text: "Törlés",
          style: "destructive",
          onPress: async () => {
            try {
              await LidarScannerModule.clearData();
              setCompletedJobId(null);
              Alert.alert("Siker", "A korábbi adatok törölve lettek.");
            } catch (error) {
              Alert.alert("Hiba", "Nem sikerült törölni az adatokat.");
            }
          }
        }
      ]
    );
  };

  const findLatestScanDir = async () => {
    try {
      const latestDir = await LidarScannerModule.getLatestScanDir();
      if (latestDir) {
        return latestDir;
      } else {
        Alert.alert("Debug Info", "Nincs Scan_ mappa a natív modul szerint.");
      }
      return null;
    } catch (error: any) {
      console.error(error);
      Alert.alert("Hiba a mappa olvasásakor", error.message);
      return null;
    }
  };

  const uploadAndProcessScan = async () => {
    setIsProcessing(true);
    setProcessStatus('Fájlok tömörítése...');

    try {
      // 1. Keresd meg a legújabb szkennelést
      const latestScanDir = await findLatestScanDir();
      if (!latestScanDir) {
        throw new Error('Nem található mentett szkennelés.');
      }

      // 2. Zipeljük be a mappát
      const targetZipPath = FileSystem.cacheDirectory + 'upload_scan.zip';
      
      // react-native-zip-archive nem szereti a file:// prefixet iOS-en
      const cleanSourcePath = latestScanDir.replace('file://', '');
      const cleanTargetPath = targetZipPath.replace('file://', '');
      
      await zip(cleanSourcePath, cleanTargetPath);

      setProcessStatus('Feltöltés a felhőbe...');

      // 3. Feltöltés a FastAPI szerverre
      const fileInfo = await FileSystem.getInfoAsync(targetZipPath);
      if (!fileInfo.exists) throw new Error('Zip fájl nem jött létre.');

      const uploadResult = await FileSystem.uploadAsync(
        `${API_URL}/upload`,
        targetZipPath,
        {
          fieldName: 'file',
          httpMethod: 'POST',
          uploadType: FileSystem.FileSystemUploadType.MULTIPART,
        }
      );

      if (uploadResult.status !== 200) {
        throw new Error(`Szerver hiba: ${uploadResult.status}`);
      }

      const responseData = JSON.parse(uploadResult.body);
      const jobId = responseData.job_id;

      // 4. Státusz lekérdezése (Polling)
      pollJobStatus(jobId);

    } catch (error: any) {
      Alert.alert('Hiba', error.message);
      setIsProcessing(false);
    }
  };

  const pollJobStatus = (jobId: string) => {
    setProcessStatus('3D Modell tanulása (Gaussian Splatting)...');

    const interval = setInterval(async () => {
      try {
        const response = await fetch(`${API_URL}/status/${jobId}`);
        const data = await response.json();

        if (data.status === 'completed') {
          clearInterval(interval);
          setCompletedJobId(jobId);
          setIsProcessing(false);
          Alert.alert('Kész!', 'A valósághű 3D modell sikeresen elkészült.');
        } else if (data.status === 'failed') {
          clearInterval(interval);
          setIsProcessing(false);
          Alert.alert('Hiba', 'A feldolgozás sikertelen volt a szerveren.');
        }
      } catch (error) {
        console.error('Polling error:', error);
      }
    }, 3000);
  };

  const handleStopScanning = async () => {
    setIsScanning(false);
    setFrameCount(0);
    // Várunk picit, hogy a Swift kód biztosan elmentse a transforms.json-t
    setTimeout(() => {
      uploadAndProcessScan();
    }, 1000);
  };

  if (isProcessing) {
    return (
      <SafeAreaView style={[styles.container, styles.centerAll]}>
        <ActivityIndicator size="large" color="#0a84ff" style={{ marginBottom: 20 }} />
        <Text style={styles.title}>Feldolgozás folyamatban</Text>
        <Text style={styles.subtitle}>{processStatus}</Text>
        <Text style={styles.instructionText}>Kérlek, ne zárd be az alkalmazást.</Text>
        <StatusBar style="light" />
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.container}>
      <View style={StyleSheet.absoluteFill}>
        <LidarScannerView
          style={StyleSheet.absoluteFill}
          isScanning={isScanning}
          onFrameCaptured={(e) => setFrameCount(e.nativeEvent.frameCount)}
          onError={(e) => {
            Alert.alert("Hiba", e.nativeEvent.message);
            setIsScanning(false);
          }}
        />
      </View>

      {isScanning ? (
        <View style={styles.scannerContainer}>
          <View style={styles.overlayTop}>
            <View style={styles.badge}>
              <Text style={styles.badgeText}>Adatpontok: {frameCount}</Text>
            </View>
          </View>
          <View style={styles.overlay}>
            <TouchableOpacity style={styles.stopButton} onPress={handleStopScanning}>
              <Text style={styles.buttonText}>Szkennelés befejezése és Feldolgozás</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : (
        <View style={[styles.homeContainer, { backgroundColor: '#1c1c1e' }]}>
          <Text style={styles.title}>Mobilscan</Text>
          <Text style={styles.subtitle}>Valósághű Ingatlan Szkennelés</Text>

          <TouchableOpacity
            style={styles.startButton}
            onPress={() => setIsScanning(true)}
          >
            <Text style={styles.buttonText}>Új szoba szkennelése</Text>
          </TouchableOpacity>

          {completedJobId && (
            <View style={styles.successContainer}>
              <Text style={styles.successTitle}>Sikeresen feldolgozva!</Text>
              <Text style={styles.instructionText}>
                Másold be ezt a linket a PC-d böngészőjébe a WASD bejáráshoz:
              </Text>
              <Text style={styles.linkText}>{API_URL}/view/{completedJobId}</Text>
            </View>
          )}

          <TouchableOpacity
            style={styles.clearButton}
            onPress={handleClearData}
          >
            <Text style={styles.clearButtonText}>Korábbi adatok törlése</Text>
          </TouchableOpacity>
        </View>
      )}
      <StatusBar style="light" />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#1c1c1e',
  },
  centerAll: {
    alignItems: 'center',
    justifyContent: 'center',
    padding: 20,
  },
  homeContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 20,
  },
  title: {
    fontSize: 34,
    fontWeight: 'bold',
    color: '#ffffff',
    marginBottom: 10,
    textAlign: 'center',
  },
  subtitle: {
    fontSize: 16,
    color: '#a1a1aa',
    marginBottom: 50,
    textAlign: 'center',
  },
  startButton: {
    backgroundColor: '#0a84ff',
    paddingHorizontal: 30,
    paddingVertical: 18,
    borderRadius: 25,
    marginBottom: 20,
    width: '80%',
    alignItems: 'center',
    shadowColor: '#0a84ff',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 10,
  },
  clearButton: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: '#ef4444',
    paddingHorizontal: 30,
    paddingVertical: 15,
    borderRadius: 25,
    marginTop: 20,
    marginBottom: 40,
    width: '80%',
    alignItems: 'center',
  },
  clearButtonText: {
    color: '#ef4444',
    fontSize: 16,
    fontWeight: '600',
  },
  buttonText: {
    color: '#ffffff',
    fontSize: 18,
    fontWeight: '600',
  },
  scannerContainer: {
    flex: 1,
    position: 'relative',
  },
  overlayTop: {
    position: 'absolute',
    top: 20,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  badge: {
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 20,
  },
  badgeText: {
    color: '#34d399',
    fontSize: 16,
    fontWeight: 'bold',
  },
  overlay: {
    position: 'absolute',
    bottom: 40,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  stopButton: {
    backgroundColor: '#ef4444',
    paddingHorizontal: 30,
    paddingVertical: 18,
    borderRadius: 30,
    shadowColor: '#ef4444',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 10,
  },
  instructionText: {
    color: '#d4d4d8',
    fontSize: 15,
    marginBottom: 5,
    lineHeight: 22,
    textAlign: 'center',
  },
  successContainer: {
    backgroundColor: '#2c2c2e',
    padding: 20,
    borderRadius: 15,
    width: '90%',
    marginTop: 10,
    marginBottom: 10,
    alignItems: 'center',
  },
  successTitle: {
    color: '#34d399',
    fontSize: 20,
    fontWeight: 'bold',
    marginBottom: 10,
  },
  linkText: {
    color: '#60a5fa',
    fontSize: 16,
    marginTop: 10,
    fontWeight: 'bold',
  }
});
