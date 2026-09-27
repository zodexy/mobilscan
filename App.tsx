import { StatusBar } from 'expo-status-bar';
import { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, SafeAreaView, Alert, ActivityIndicator } from 'react-native';
import * as FileSystem from 'expo-file-system/legacy';
import * as Sharing from 'expo-sharing';
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

  const exportScanAsZip = async () => {
    setIsProcessing(true);
    setProcessStatus('Adatok tömörítése és előkészítése...');

    try {
      const latestScanDir = await findLatestScanDir();
      if (!latestScanDir) {
        throw new Error('Nincs korábbi szkennelés a telefonon.');
      }

      let cleanSourcePath = decodeURI(latestScanDir).replace('file://', '');
      if (cleanSourcePath.endsWith('/')) {
        cleanSourcePath = cleanSourcePath.slice(0, -1);
      }
      
      let cleanTargetPath = cleanSourcePath + '.zip';
      
      try {
        await zip(cleanSourcePath, cleanTargetPath);
      } catch (zipError: any) {
        throw new Error(`Zip hiba: ${zipError.message}`);
      }

      const fileUriForUpload = 'file://' + cleanTargetPath;
      const fileInfo = await FileSystem.getInfoAsync(fileUriForUpload);
      if (!fileInfo.exists) throw new Error('Zip fájl nem jött létre.');

      setIsProcessing(false);
      
      if (await Sharing.isAvailableAsync()) {
        await Sharing.shareAsync(fileUriForUpload, {
          mimeType: 'application/zip',
          dialogTitle: 'Szkennelés exportálása (2DGS/3DGS-hez)',
          UTI: 'public.zip-archive'
        });
      } else {
        Alert.alert("Hiba", "A megosztás (iOS Share Sheet) nem támogatott ezen az eszközön.");
      }

    } catch (error: any) {
      Alert.alert('Hiba', error.message);
      setIsProcessing(false);
    }
  };

  const handleStopScanning = async () => {
    setIsScanning(false);
    setFrameCount(0);
    // Várunk picit, hogy a Swift kód biztosan elmentse a fájlokat (obj, json, stb)
    setTimeout(async () => {
      try {
        const latestScanDir = await findLatestScanDir();
        if (latestScanDir) {
          Alert.alert(
            'Kész!', 
            `A szkennelés sikeresen mentve lett a telefonodra!\n\nEzt a mappát (benne a sparse_pc.ply-vel) átmásolhatod a PC-dre a 2DGS tanításhoz:\n\n${decodeURI(latestScanDir)}`
          );
        }
      } catch (error) {
        console.error(error);
      }
    }, 1500);
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
              <Text style={styles.buttonText}>Szkennelés befejezése és Mentés</Text>
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

          <TouchableOpacity
            style={[styles.startButton, { backgroundColor: '#34d399' }]}
            onPress={exportScanAsZip}
          >
            <Text style={[styles.buttonText, { color: '#000' }]}>Szkennelés exportálása (ZIP)</Text>
          </TouchableOpacity>

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
  }
});
