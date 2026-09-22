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
          valueListenable: ConnectivityService.instance.serverType,
          builder: (context, serverType, child) {
            final String label;
            final Color bgColor;
            if (!connected) {
              label = '未连接';
              bgColor = AppColors.error;
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
  }
}
