// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.Build;
import androidx.annotation.Nullable;
import java.io.InputStream;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.Enumeration;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManagerFactory;

/**
 * 为 Android 5.x（API < 23）提供兼容现代 CA 的 SSLSocketFactory。
 *
 * <p>旧系统内置根证书库较老，播放 HTTPS 片源时容易出现
 * "Trust anchor for certification path not found"，导致 ExoPlayer 报 Source error。
 * 本类将系统根证书与插件内置的常用根证书（如 Let's Encrypt ISRG Root X1/X2）合并，
 * 仅对 API < 23 生效；高版本直接返回 null 使用系统默认实现。
 */
final class SslSocketFactoryProvider {

  /** 内置根证书资源 ID 列表。 */
  private static final int[] BUNDLED_CA_RESOURCES = {
    R.raw.isrg_root_x1,
    R.raw.isrg_root_x2,
  };

  /**
   * 返回适用于低版本系统的 SSLSocketFactory；高版本返回 null。
   *
   * @param context 用于读取 raw 资源的 Context。
   * @return 自定义 SSLSocketFactory，或 null（表示使用系统默认）。
   */
  @Nullable
  static SSLSocketFactory getLegacyCompatibleSocketFactory(Context context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      return null;
    }
    try {
      // 1. 复制系统根证书到新的 KeyStore。
      KeyStore combined = KeyStore.getInstance(KeyStore.getDefaultType());
      combined.load(null, null);

      KeyStore systemStore = KeyStore.getInstance("AndroidCAStore");
      systemStore.load(null, null);
      Enumeration<String> aliases = systemStore.aliases();
      while (aliases.hasMoreElements()) {
        String alias = aliases.nextElement();
        Certificate cert = systemStore.getCertificate(alias);
        if (cert != null) {
          combined.setCertificateEntry(alias, cert);
        }
      }

      // 2. 追加内置根证书，覆盖旧系统缺失的常见 CA。
      CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
      for (int resId : BUNDLED_CA_RESOURCES) {
        addCertificateFromResource(context, combined, certificateFactory, resId);
      }

      // 3. 使用合并后的 KeyStore 创建 TrustManagerFactory。
      TrustManagerFactory trustManagerFactory =
          TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
      trustManagerFactory.init(combined);

      SSLContext sslContext = SSLContext.getInstance("TLS");
      sslContext.init(null, trustManagerFactory.getTrustManagers(), null);
      return sslContext.getSocketFactory();
    } catch (Exception e) {
      // 兜底：出现异常时回退到系统默认，避免引入新的播放失败。
      return null;
    }
  }

  private static void addCertificateFromResource(
      Context context,
      KeyStore keyStore,
      CertificateFactory certificateFactory,
      int resourceId)
      throws Exception {
    InputStream inputStream = context.getResources().openRawResource(resourceId);
    try {
      Certificate certificate = certificateFactory.generateCertificate(inputStream);
      String alias = "bundled_" + resourceId;
      keyStore.setCertificateEntry(alias, certificate);
    } finally {
      inputStream.close();
    }
  }
}
