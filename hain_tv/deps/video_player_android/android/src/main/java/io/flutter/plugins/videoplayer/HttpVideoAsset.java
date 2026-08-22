// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.net.Uri;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.okhttp.OkHttpDataSource;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.source.MediaSource;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import okhttp3.OkHttpClient;

final class HttpVideoAsset extends VideoAsset {
  /** 通过 httpHeaders 传递单条播放代理地址的内部键，构造前会被剥离，不会发送到上游。 */
  private static final String PROXY_URL_HEADER = "x-heinplay-proxy-url";

  @NonNull private final StreamingFormat streamingFormat;
  @NonNull private final Map<String, String> httpHeaders;
  @Nullable private final String userAgent;
  @Nullable private final String proxyUrl;

  HttpVideoAsset(
      @Nullable String assetUrl,
      @NonNull StreamingFormat streamingFormat,
      @NonNull Map<String, String> httpHeaders,
      @Nullable String userAgent) {
    super(assetUrl);
    this.streamingFormat = streamingFormat;
    // 拷贝一份并剥离内部代理键，避免该特殊请求头被发送到上游。
    Map<String, String> headers = new HashMap<>(httpHeaders);
    String proxy = headers.remove(PROXY_URL_HEADER);
    this.httpHeaders = headers;
    this.userAgent = userAgent;
    this.proxyUrl = proxy;
  }

  @NonNull
  @Override
  public MediaItem getMediaItem() {
    MediaItem.Builder builder = new MediaItem.Builder().setUri(assetUrl);
    String mimeType = null;
    switch (streamingFormat) {
      case SMOOTH:
        mimeType = MimeTypes.APPLICATION_SS;
        break;
      case DYNAMIC_ADAPTIVE:
        mimeType = MimeTypes.APPLICATION_MPD;
        break;
      case HTTP_LIVE:
        mimeType = MimeTypes.APPLICATION_M3U8;
        break;
    }
    if (mimeType != null) {
      builder.setMimeType(mimeType);
    }
    return builder.build();
  }

  @NonNull
  @Override
  public MediaSource.Factory getMediaSourceFactory(@NonNull Context context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      OkHttpClient.Builder clientBuilder = createOkHttpClientBuilder(proxyUrl);
      return getMediaSourceFactory(context, new OkHttpDataSource.Factory(clientBuilder.build()));
    }
    // Android 5.x 继续使用 DefaultHttpDataSource，依赖 VideoPlayerPlugin 中全局设置的 SSLSocketFactory。
    DefaultHttpDataSource.Factory initialFactory = new DefaultHttpDataSource.Factory();
    unstableUpdateLegacyDataSourceFactory(initialFactory, httpHeaders, userAgent);
    DataSource.Factory dataSourceFactory = new DefaultDataSource.Factory(context, initialFactory);
    return new DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory);
  }

  /**
   * Returns a configured media source factory, starting at the provided OkHttp factory.
   *
   * <p>This method is provided for ease of testing without making real HTTP calls.
   */
  @VisibleForTesting
  MediaSource.Factory getMediaSourceFactory(
      Context context, OkHttpDataSource.Factory initialFactory) {
    unstableUpdateDataSourceFactory(initialFactory, httpHeaders, userAgent);
    DataSource.Factory dataSourceFactory = new DefaultDataSource.Factory(context, initialFactory);
    return new DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory);
  }

  /**
   * 创建用于 ExoPlayer 网络请求的 OkHttpClient。
   *
   * <p>相比默认的 HttpURLConnection，OkHttp 对自定义代理、TLS 证书、连接池的支持更完善，
   * 可以改善部分 IPTV 源在 ExoPlayer 后端无法播放的问题。
   */
  @NonNull
  private static OkHttpClient.Builder createOkHttpClientBuilder(@Nullable String proxyUrl) {
    OkHttpClient.Builder builder =
        new OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true);

    if (proxyUrl != null && !proxyUrl.isEmpty()) {
      Proxy parsed = parseProxy(proxyUrl);
      if (parsed != null) {
        builder.proxy(parsed);
      }
    }

    return builder;
  }

  @Nullable
  private static Proxy parseProxy(@NonNull String proxyUrl) {
    try {
      Uri uri = Uri.parse(proxyUrl);
      String scheme = uri.getScheme();
      if (scheme == null) return null;
      String host = uri.getHost();
      if (host == null) return null;
      int port = uri.getPort();
      if (port <= 0) {
        if (scheme.equalsIgnoreCase("https")) {
          port = 443;
        } else {
          port = 80;
        }
      }
      Proxy.Type type = scheme.equalsIgnoreCase("socks") ? Proxy.Type.SOCKS : Proxy.Type.HTTP;
      return new Proxy(type, new InetSocketAddress(host, port));
    } catch (Exception e) {
      return null;
    }
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @OptIn(markerClass = UnstableApi.class)
  private static void unstableUpdateDataSourceFactory(
      @NonNull OkHttpDataSource.Factory factory,
      @NonNull Map<String, String> httpHeaders,
      @Nullable String userAgent) {
    factory.setUserAgent(userAgent);
    if (!httpHeaders.isEmpty()) {
      factory.setDefaultRequestProperties(httpHeaders);
    }
  }

  @OptIn(markerClass = UnstableApi.class)
  private static void unstableUpdateLegacyDataSourceFactory(
      @NonNull DefaultHttpDataSource.Factory factory,
      @NonNull Map<String, String> httpHeaders,
      @Nullable String userAgent) {
    factory.setUserAgent(userAgent).setAllowCrossProtocolRedirects(true);
    if (!httpHeaders.isEmpty()) {
      factory.setDefaultRequestProperties(httpHeaders);
    }
  }
}
