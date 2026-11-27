import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/sources/source_api.dart' as source_api;

enum AuthStatus { initial, authenticated, unauthenticated, loading, error }

enum CheckcodeStatus { initial, loading, success, error }

class AuthState extends Equatable {
  final AuthStatus status;
  final String? username;
  final String? errorMessage;
  final Uint8List? checkcode;
  final CheckcodeStatus checkcodeStatus;
  final String? checkcodeErrorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.username,
    this.errorMessage,
    this.checkcode,
    this.checkcodeStatus = CheckcodeStatus.initial,
    this.checkcodeErrorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? username,
    bool clearUsername = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    Uint8List? checkcode,
    bool clearCheckcode = false,
    CheckcodeStatus? checkcodeStatus,
    String? checkcodeErrorMessage,
    bool clearCheckcodeErrorMessage = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      username: clearUsername ? null : username ?? this.username,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      checkcode: clearCheckcode ? null : checkcode ?? this.checkcode,
      checkcodeStatus: checkcodeStatus ?? this.checkcodeStatus,
      checkcodeErrorMessage:
          clearCheckcodeErrorMessage
              ? null
              : checkcodeErrorMessage ?? this.checkcodeErrorMessage,
    );
  }

  @override
  List<Object?> get props => [
    status,
    username,
    errorMessage,
    checkcode,
    checkcodeStatus,
    checkcodeErrorMessage,
  ];
}

typedef Wenku8Login =
    Future<void> Function({
      required String username,
      required String password,
      required String checkcode,
    });
typedef PreLoginState = Future<bool> Function();
typedef DownloadCheckcode = Future<Uint8List> Function();

class AuthCubit extends Cubit<AuthState> {
  AuthCubit({
    Wenku8Login? login,
    PreLoginState? preLoginState,
    DownloadCheckcode? downloadCheckcode,
    Stream<void>? sessionInvalidations,
  }) : _login = login ?? source_api.wenku8Login,
       _preLoginState = preLoginState ?? source_api.preLoginState,
       _downloadCheckcode = downloadCheckcode ?? source_api.downloadCheckcode,
       super(const AuthState()) {
    _sessionInvalidationSubscription = (sessionInvalidations ??
            Wenku8BrowserSession.instance.sessionInvalidations)
        .listen(_handleSessionInvalidation);
  }

  final Wenku8Login _login;
  final PreLoginState _preLoginState;
  final DownloadCheckcode _downloadCheckcode;
  late final StreamSubscription<void> _sessionInvalidationSubscription;

  int _authTicket = 0;
  int _captchaGeneration = 0;

  void _handleSessionInvalidation(void _) {
    if (isClosed || state.status == AuthStatus.loading) return;

    final ticket = ++_authTicket;
    unawaited(_recheckSession(ticket));
  }

  Future<void> _recheckSession(int ticket) async {
    bool loggedIn;
    try {
      loggedIn = await _preLoginState();
    } catch (_) {
      loggedIn = false;
    }

    if (!_isCurrentAuthTicket(ticket)) return;
    if (loggedIn) return;

    ++_captchaGeneration;
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  Future<void> login(String username, String password, String checkcode) async {
    if (isClosed ||
        state.status == AuthStatus.loading ||
        state.checkcodeStatus == CheckcodeStatus.loading) {
      return;
    }

    final ticket = ++_authTicket;
    ++_captchaGeneration;
    if (!isClosed) {
      emit(
        state.copyWith(
          status: AuthStatus.loading,
          username: username,
          clearErrorMessage: true,
        ),
      );
    }

    try {
      await _login(
        username: username,
        password: password,
        checkcode: checkcode,
      );
      if (!_isCurrentAuthTicket(ticket)) return;
      emit(
        state.copyWith(
          status: AuthStatus.authenticated,
          username: username,
          clearErrorMessage: true,
        ),
      );
    } catch (error) {
      if (!_isCurrentAuthTicket(ticket)) return;
      emit(
        state.copyWith(
          status: AuthStatus.error,
          username: username,
          errorMessage: error.toString(),
        ),
      );
    }
  }

  void logout() {
    if (isClosed) return;
    ++_authTicket;
    ++_captchaGeneration;
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  Future<void> init() async {
    if (isClosed) return;
    final ticket = ++_authTicket;
    ++_captchaGeneration;

    if (state.checkcodeStatus == CheckcodeStatus.loading && !isClosed) {
      emit(
        state.copyWith(
          clearCheckcode: true,
          checkcodeStatus: CheckcodeStatus.initial,
          clearCheckcodeErrorMessage: true,
        ),
      );
    }

    bool loggedIn;
    try {
      loggedIn = await _preLoginState();
    } catch (_) {
      if (!_isCurrentAuthTicket(ticket)) return;
      emit(
        state.copyWith(
          status: AuthStatus.unauthenticated,
          clearErrorMessage: true,
        ),
      );
      return;
    }
    if (!_isCurrentAuthTicket(ticket)) return;
    emit(
      state.copyWith(
        status:
            loggedIn ? AuthStatus.authenticated : AuthStatus.unauthenticated,
        clearErrorMessage: true,
      ),
    );
  }

  Future loadCheckcode() async {
    if (isClosed || state.status == AuthStatus.loading) return;

    final generation = ++_captchaGeneration;
    emit(
      state.copyWith(
        checkcode: Uint8List(0),
        checkcodeStatus: CheckcodeStatus.loading,
        clearCheckcodeErrorMessage: true,
      ),
    );

    try {
      final checkcode = await _downloadCheckcode();
      if (!_isCurrentCaptchaRequest(generation)) return;
      emit(
        state.copyWith(
          checkcode: checkcode,
          checkcodeStatus: CheckcodeStatus.success,
          clearCheckcodeErrorMessage: true,
        ),
      );
    } catch (error) {
      if (!_isCurrentCaptchaRequest(generation)) return;
      emit(
        state.copyWith(
          clearCheckcode: true,
          checkcodeStatus: CheckcodeStatus.error,
          checkcodeErrorMessage: _safeCheckcodeError(error),
        ),
      );
    }
  }

  bool _isCurrentAuthTicket(int ticket) => !isClosed && ticket == _authTicket;

  bool _isCurrentCaptchaRequest(int generation) =>
      !isClosed && generation == _captchaGeneration;

  String _safeCheckcodeError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('验证码已过期') ||
        message.contains('checkcode expired') ||
        message.contains('verification code expired')) {
      return '验证码已过期，请刷新验证码后重试。';
    }

    if (RegExp(r'(^|\D)403(\D|$)').hasMatch(message)) {
      return '文库8站点验证未通过（HTTP 403）。请先在文库8站点完成验证后重试。';
    }
    if (message.contains('cf_challenge') || message.contains('站点验证')) {
      return '文库8要求站点验证，请先打开站点完成验证后重试。';
    }

    const networkMarkers = [
      'timeout',
      'timed out',
      'connection',
      'connect',
      'network',
      'socket',
      'dns',
      'tls',
      'eof',
    ];
    if (networkMarkers.any(message.contains)) {
      return '网络连接失败，无法获取验证码，请检查网络后重试。';
    }
    return '无法获取验证码，请稍后重试。';
  }

  @override
  Future<void> close() async {
    ++_authTicket;
    ++_captchaGeneration;
    await _sessionInvalidationSubscription.cancel();
    await super.close();
  }
}
