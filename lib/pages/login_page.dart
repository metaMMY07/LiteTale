import 'package:flutter/material.dart';
import 'package:wild/widgets/app_color_settings.dart';
import 'package:wild/theme/material_you.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/widgets/wenku8_verification_page.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _checkcodeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final authCubit = context.read<AuthCubit>();
    authCubit.loadCheckcode();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _checkcodeController.dispose();
    super.dispose();
  }

  void _onLoginPressed() {
    final state = context.read<AuthCubit>().state;
    if (state.status == AuthStatus.loading ||
        state.checkcodeStatus != CheckcodeStatus.success ||
        state.checkcode == null ||
        state.checkcode!.isEmpty) {
      return;
    }
    if (_formKey.currentState?.validate() ?? false) {
      context.read<AuthCubit>().login(
        _usernameController.text,
        _passwordController.text,
        _checkcodeController.text,
      );
    }
  }

  void _refreshCaptcha() {
    _checkcodeController.clear();
    context.read<AuthCubit>().loadCheckcode();
  }

  Future<void> _openSiteLogin() async {
    final auth = context.read<AuthCubit>();
    try {
      final host = await Wenku8BrowserSession.instance.apiHost();
      if (!mounted) return;
      final authenticated = await Navigator.of(context).push<bool>(
        HorizontalCoverPageRoute<bool>(
          builder:
              (_) => Wenku8VerificationPage(
                apiHost: host,
                sessionOnly: true,
                startAtLogin: true,
              ),
        ),
      );
      if (!mounted) return;
      if (authenticated == true) {
        // init may preserve an already authenticated status during re-login.
        await auth.init();
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop(true);
        }
      } else {
        await auth.init();
        if (!mounted) return;
        _refreshCaptcha();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开文库8站点，请检查网络后重试。')));
      }
    }
  }

  Future<void> _onRegisterPressed() async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('注册提示'),
            content: const Text('注册需要在网页端进行，是否跳转到注册页面？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
    );

    if (result == true) {
      final uri = Uri.parse(
        '${await Wenku8BrowserSession.instance.apiHost()}/register.php',
      );
      if (!await launchUrl(uri)) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法打开注册页面')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(usesMaterialYou ? '欢迎来到 LiteTale' : '登录轻小说文库'),
        actions: [
          if (usesMaterialYou)
            IconButton(
              tooltip: '主题配色',
              icon: const Icon(Icons.palette_outlined),
              onPressed: () => showAppColors(context),
            ),
        ],
      ),
      body: BlocConsumer<AuthCubit, AuthState>(
        listenWhen: (previous, current) => previous.status != current.status,
        listener: (context, state) {
          if (state.status == AuthStatus.error) {
            var message = '登录失败，请检查网络连接';
            var err = state.errorMessage ?? "";
            if (err.contains('站点验证') ||
                err.contains('403') ||
                err.contains('cf_challenge')) {
              message = '文库8要求站点验证，请点下方“打开站点验证 / 登录”。';
            } else if (err.contains('验证码已过期') || err.contains('表单已改变')) {
              message = '验证码已过期，请刷新验证码后登录。';
            } else if (err.contains('结果未能确认')) {
              message = '登录结果未能确认，请打开站点查看后再返回。';
            }
            if (err.contains("用户不存在") || err.contains("用戶不存在")) {
              message = "用户不存在";
            } else if (err.contains("密码错误") || err.contains("密碼錯誤")) {
              message = "密码错误";
            } else if (err.contains("校验码错误") || err.contains("校驗碼錯誤")) {
              message = "验证码错误";
            } else if (err.contains("用户登录") || err.contains("用戶登錄")) {
              message = "用户登录";
            } else if (err.contains("验证码过期") || err.contains("驗證碼過期")) {
              message = "验证码过期";
            }
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          } else if (state.status == AuthStatus.authenticated) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true);
            } else {
              Navigator.of(context).pushReplacementNamed('/home');
            }
          }
        },
        builder: (context, state) {
          if (state.status == AuthStatus.initial) {
            return const CenteredLoadingIndicator();
          }
          return SafeArea(
            child: LeftAlignedScrollView(
              phoneInset: 24,
              topInset: 20,
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child:
                          usesMaterialYou
                              ? CircleAvatar(
                                radius: 40,
                                backgroundColor:
                                    Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                child: Icon(
                                  Icons.auto_stories_rounded,
                                  size: 40,
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer,
                                ),
                              )
                              : Image.asset(
                                'lib/assets/icon.png',
                                width: 96,
                                height: 96,
                              ),
                    ),
                    if (usesMaterialYou) ...[
                      Text(
                        '下一段故事，从这里开始',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '使用文库8账号，同步你的书架',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 28),
                    ],
                    TextFormField(
                      controller: _usernameController,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                      validator: (value) {
                        if (value?.isEmpty ?? true) {
                          return '请输入用户名';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(
                        labelText: '密码',
                        prefixIcon: Icon(Icons.lock_outline_rounded),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value?.isEmpty ?? true) {
                          return '请输入密码';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    Builder(
                      builder: (context) {
                        switch (state.checkcodeStatus) {
                          case CheckcodeStatus.loading:
                            return const SizedBox(
                              width: 200,
                              height: 50,
                              child: Center(child: CircularProgressIndicator()),
                            );
                          case CheckcodeStatus.success:
                            if (state.checkcode == null ||
                                state.checkcode!.isEmpty) {
                              return _buildRetryButton(context);
                            }
                            return GestureDetector(
                              onTap:
                                  state.status == AuthStatus.loading
                                      ? null
                                      : _refreshCaptcha,
                              child: Image.memory(
                                state.checkcode!,
                                width: 200,
                                height: 50,
                                fit: BoxFit.contain,
                                errorBuilder:
                                    (_, __, ___) => _buildRetryButton(context),
                              ),
                            );
                          case CheckcodeStatus.error:
                          case CheckcodeStatus.initial:
                            return _buildRetryButton(context);
                        }
                      },
                    ),
                    if (state.checkcodeStatus == CheckcodeStatus.error) ...[
                      const SizedBox(height: 8),
                      Text(
                        state.checkcodeErrorMessage ?? '验证码加载失败，请刷新或打开站点验证。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          state.status == AuthStatus.loading
                              ? null
                              : _openSiteLogin,
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('打开站点验证 / 登录'),
                    ),
                    Container(height: 20),
                    TextFormField(
                      controller: _checkcodeController,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (state.status != AuthStatus.loading) {
                          _onLoginPressed();
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        prefixIcon: Icon(Icons.verified_user_outlined),
                      ),
                      validator: (value) {
                        if (value?.isEmpty ?? true) {
                          return '请输入验证码';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: OutlinedButton(
                            onPressed: _onRegisterPressed,
                            child: const Text('注册'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed:
                                state.status == AuthStatus.loading ||
                                        state.checkcodeStatus !=
                                            CheckcodeStatus.success
                                    ? null
                                    : _onLoginPressed,
                            child:
                                state.status == AuthStatus.loading
                                    ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Text('登录'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRetryButton(BuildContext context) {
    return InkWell(
      onTap: _refreshCaptcha,
      child: Container(
        width: 200,
        height: 50,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(child: Text('验证码未加载 · 点此刷新')),
      ),
    );
  }
}
