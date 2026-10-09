import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  UserModel? _currentUser;
  UserModel? get currentUser => _currentUser;

  bool get isFirebaseAvailable => Firebase.apps.isNotEmpty;

  /// Initialize Auth state from stored session or Firebase
  Future<UserModel?> initialize() async {
    if (isFirebaseAvailable) {
      try {
        final fbUser = fb_auth.FirebaseAuth.instance.currentUser;
        if (fbUser != null) {
          _currentUser = UserModel(
            userId: fbUser.uid,
            name: fbUser.displayName ?? fbUser.email?.split('@').first ?? 'Beauty Lover',
            email: fbUser.email ?? '',
          );
          return _currentUser;
        }
      } catch (e) {
        debugPrint('Firebase auth check error: $e');
      }
    }

    // Fallback: Check local prefs
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('current_user_session');
    if (userJson != null) {
      try {
        _currentUser = UserModel.fromMap(jsonDecode(userJson));
      } catch (e) {
        debugPrint('Prefs user decode error: $e');
      }
    }
    return _currentUser;
  }

  /// Sign In with email and password
  Future<UserModel> signIn({required String email, required String password}) async {
    if (isFirebaseAvailable) {
      try {
        final creds = await fb_auth.FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        final fbUser = creds.user!;
        final user = UserModel(
          userId: fbUser.uid,
          name: fbUser.displayName ?? email.split('@').first,
          email: fbUser.email ?? email,
        );
        _currentUser = user;
        await _saveSession(user);
        return user;
      } on fb_auth.FirebaseAuthException catch (e) {
        throw Exception(e.message ?? 'Authentication failed');
      } catch (e) {
        debugPrint('Firebase signin fallback: $e');
      }
    }

    // Local / Offline demo authentication
    await Future.delayed(const Duration(milliseconds: 400));
    final user = UserModel(
      userId: 'user_${email.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}',
      name: email.split('@').first,
      email: email,
    );
    _currentUser = user;
    await _saveSession(user);
    return user;
  }

  /// Sign Up with name, email, and password
  Future<UserModel> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    if (isFirebaseAvailable) {
      try {
        final creds = await fb_auth.FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        final fbUser = creds.user!;
        await fbUser.updateDisplayName(name);
        final user = UserModel(
          userId: fbUser.uid,
          name: name,
          email: fbUser.email ?? email,
        );
        _currentUser = user;
        await _saveSession(user);
        return user;
      } on fb_auth.FirebaseAuthException catch (e) {
        throw Exception(e.message ?? 'Registration failed');
      } catch (e) {
        debugPrint('Firebase signup fallback: $e');
      }
    }

    // Local / Offline demo signup
    await Future.delayed(const Duration(milliseconds: 400));
    final user = UserModel(
      userId: 'user_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      email: email,
    );
    _currentUser = user;
    await _saveSession(user);
    return user;
  }

  /// Sign Out
  Future<void> signOut() async {
    if (isFirebaseAvailable) {
      try {
        await fb_auth.FirebaseAuth.instance.signOut();
      } catch (e) {
        debugPrint('Firebase signout error: $e');
      }
    }
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user_session');
  }

  Future<void> _saveSession(UserModel user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_user_session', jsonEncode(user.toMap()));
  }
}
