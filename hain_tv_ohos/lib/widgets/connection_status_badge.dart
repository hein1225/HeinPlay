import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../theme.dart';

/// 服务器连接状态文字徽标。
///
/// 根据 [ConnectivityService] 的实时状态显示：
/// - 互联网已连接：蓝色背景 + 白色文字
/// - 局域网已连接：绿色背景 + 白色文字
/// - 未连接：红色背景 + 白色文字
class ConnectionStatusBadge extends StatelessWidget {
  const ConnectionStatusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.isServerConnected,
      builder: (context, connected, child) {
        return ValueListenableBuilder<String>(
          valueListenable: ConnectivityService.instance.configuredServerUrl,
          builder: (context, configuredUrl, child) {
            return ValueListenableBuilder<String>(
              valueListenable: ConnectivityService.instance.serverType,
              builder: (context, serverType, child) {
            final String label;
            final Color bgColor;
            if (!connected) {
              // 🔴 2026-10-31：区分「无服务器」与「未连接」。
              //   · 从未配置服务器 → 「无服务器」（中性灰），属游客态正常形态；
              //   · 配置了服务器但连不上 → 「未连接」（红），需要用户处理。
              if (configuredUrl.trim().isEmpty) {
                label = '无服务器';
                bgColor = AppColors.neutral;
              } else {
                label = '未连接';
                bgColor = AppColors.error;
              }
            } else if (serverType == 'lan') {
              label = '局域网已连接';
              bgColor = AppColors.success;
            } else {
              label = '互联网已连接';
              bgColor = AppColors.info;
            }
            return Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            );
              },
            );
          },
        );
      },
    );
  }
}
