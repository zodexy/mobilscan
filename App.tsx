import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, SafeAreaView, Alert } from 'react-native';
import LidarScannerView from './modules/lidar-scanner/src/LidarScannerView';
import LidarScannerModule from './modules/lidar-scanner/src/LidarScannerModule';

export default function App() {
  const [isScanning, setIsScanning] = useState(false);
  const [frameCount, setFrameCount] = useState(0);

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

  return (
    <SafeAreaView style={styles.container}>
      <View style={StyleSheet.absoluteFill}>
        <LidarScannerView 
          style={StyleSheet.absoluteFill} 
          isScanning={isScanning} 
          onFrameCaptured={(e) => setFrameCount(e.nativeEvent.frameCount)}
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
            <TouchableOpacity 
              style={styles.stopButton} 
              onPress={() => {
                setIsScanning(false);
                setFrameCount(0);
              }}
            >
              <Text style={styles.buttonText}>Szkennelés leállítása</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : (
        <View style={[styles.homeContainer, { backgroundColor: '#1c1c1e' }]}>
          <Text style={styles.title}>Mobilscan</Text>
          <Text style={styles.subtitle}>LiDAR & Gaussian Splatting</Text>
          
          <TouchableOpacity 
            style={styles.startButton} 
            onPress={() => setIsScanning(true)}
          >
            <Text style={styles.buttonText}>Új szoba szkennelése</Text>
          </TouchableOpacity>

          <TouchableOpacity 
            style={styles.clearButton} 
            onPress={handleClearData}
          >
            <Text style={styles.clearButtonText}>Korábbi adatok törlése</Text>
          </TouchableOpacity>

          <View style={styles.instructionsContainer}>
            <Text style={styles.instructionTitle}>Adatok letöltése gépre:</Text>
            <Text style={styles.instructionText}>1. Csatlakoztasd a telefont vagy nyisd meg a "Fájlok" appot a telefonodon.</Text>
            <Text style={styles.instructionText}>2. Keresd meg az "On My iPhone / Mobilscan" mappát.</Text>
            <Text style={styles.instructionText}>3. Másold át a "Scan_..." mappákat a számítógépedre a Gaussian Splatting Colab számára.</Text>
          </View>
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
  },
  subtitle: {
    fontSize: 16,
    color: '#a1a1aa',
    marginBottom: 60,
  },
  startButton: {
    backgroundColor: '#0a84ff',
    paddingHorizontal: 30,
    paddingVertical: 18,
    borderRadius: 25,
    marginBottom: 20,
    width: '80%',
    alignItems: 'center',
  },
  clearButton: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: '#ef4444',
    paddingHorizontal: 30,
    paddingVertical: 15,
    borderRadius: 25,
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
  scanner: {
    flex: 1,
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
    paddingHorizontal: 40,
    paddingVertical: 18,
    borderRadius: 30,
  },
  instructionsContainer: {
    backgroundColor: '#2c2c2e',
    padding: 20,
    borderRadius: 15,
    width: '100%',
    marginTop: 20,
  },
  instructionTitle: {
    color: '#ffffff',
    fontSize: 18,
    fontWeight: 'bold',
    marginBottom: 10,
  },
  instructionText: {
    color: '#d4d4d8',
    fontSize: 14,
    marginBottom: 5,
    lineHeight: 20,
  }
});
