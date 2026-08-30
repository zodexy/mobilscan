import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, SafeAreaView } from 'react-native';
import LidarScannerView from './modules/lidar-scanner/src/LidarScannerView';

export default function App() {
  const [isScanning, setIsScanning] = useState(false);

  return (
    <SafeAreaView style={styles.container}>
      {isScanning ? (
        <View style={styles.scannerContainer}>
          <LidarScannerView 
            style={styles.scanner} 
            isScanning={true} 
          />
          <View style={styles.overlay}>
            <TouchableOpacity 
              style={styles.stopButton} 
              onPress={() => setIsScanning(false)}
            >
              <Text style={styles.buttonText}>Szkennelés leállítása</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : (
        <View style={styles.homeContainer}>
          <Text style={styles.title}>Ingatlan Scanner</Text>
          <Text style={styles.subtitle}>LiDAR & Gaussian Splatting</Text>
          
          <TouchableOpacity 
            style={styles.startButton} 
            onPress={() => setIsScanning(true)}
          >
            <Text style={styles.buttonText}>Új szoba szkennelése</Text>
          </TouchableOpacity>
        </View>
      )}
      <StatusBar style="auto" />
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
    fontSize: 28,
    fontWeight: 'bold',
    color: '#ffffff',
    marginBottom: 10,
  },
  subtitle: {
    fontSize: 16,
    color: '#a1a1aa',
    marginBottom: 40,
  },
  startButton: {
    backgroundColor: '#0a7ea4',
    paddingHorizontal: 30,
    paddingVertical: 15,
    borderRadius: 25,
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
    paddingVertical: 15,
    borderRadius: 25,
  },
});
