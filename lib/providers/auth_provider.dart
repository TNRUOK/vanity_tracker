import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();

  UserModel? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;

  UserModel? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get isDemoAccount => _currentUser?.isDemoAccount ?? false;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();
    try {
      _currentUser = await _authService.initialize();
    } catch (e) {
      debugPrint('AuthProvider initialize error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _currentUser = await _authService.signIn(email: email, password: password);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> signUp(String name, String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _currentUser = await _authService.signUp(name: name, email: email, password: password);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> useDemoAccount() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    _currentUser = const UserModel(
      userId: 'demo_user',
      name: 'Skincare Aficionado',
      email: 'vanity@demo.app',
    );
    _isLoading = false;
    notifyListeners();
  }

  /// Re-sends the verification e-mail. Returns an error message, or null on success.
  Future<String?> sendVerificationEmail() async {
    try {
      await _authService.sendEmailVerification();
      return null;
    } catch (e) {
      return e.toString().replaceAll('Exception: ', '');
    }
  }

  /// Picks up a verification completed in the e-mail link (reloads the account and
  /// refreshes the ID token). Returns true when the address is now verified.
  Future<bool> refreshEmailVerification() async {
    try {
      final updated = await _authService.refreshEmailVerification();
      if (updated != null) _currentUser = updated;
    } catch (e) {
      debugPrint('Verification refresh failed: $e');
    }
    notifyListeners();
    return _currentUser?.emailVerified ?? false;
  }

  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();
    await _authService.signOut();
    _currentUser = null;
    _isLoading = false;
    notifyListeners();
  }
}
