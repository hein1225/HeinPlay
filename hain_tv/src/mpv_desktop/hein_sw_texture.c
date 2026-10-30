// HeinPlay 软件渲染纹理实现。见 hein_sw_texture.h 的完整说明。
#include "hein_sw_texture.h"

#include <string.h>

struct _HeinSwTexture {
  FlPixelBufferTexture parent_instance;

  // 双缓冲：写入侧（mpv 渲染线程）与读取侧（Flutter raster 线程）分离，
  // 避免 copy_pixels 拿到正在被改写的半帧。
  uint8_t* front;  // copy_pixels 返回的缓冲（稳定，不释放）
  uint8_t* back;   // 写入侧
  uint32_t width;
  uint32_t height;

  GMutex mutex;
  gboolean has_frame;
};

G_DEFINE_TYPE(HeinSwTexture, hein_sw_texture, fl_pixel_buffer_texture_get_type())

static void hein_sw_texture_finalize(GObject* object) {
  HeinSwTexture* self = HEIN_SW_TEXTURE(object);
  g_free(self->front);
  g_free(self->back);
  g_mutex_clear(&self->mutex);
  G_OBJECT_CLASS(hein_sw_texture_parent_class)->finalize(object);
}

static gboolean hein_sw_texture_copy_pixels(FlPixelBufferTexture* texture,
                                            const uint8_t** out_buffer,
                                            uint32_t* width, uint32_t* height,
                                            GError** error) {
  HeinSwTexture* self = HEIN_SW_TEXTURE(texture);
  g_mutex_lock(&self->mutex);
  if (!self->has_frame || self->front == NULL || self->width == 0 ||
      self->height == 0) {
    g_mutex_unlock(&self->mutex);
    // 还没有帧：返回 1x1 全黑占位，保证 Flutter 侧纹理始终有效
    // （首次 populate 若返回 FALSE，引擎会永久放弃该纹理）。
    static uint8_t s_black[4] = {0, 0, 0, 255};
    *out_buffer = s_black;
    *width = 1;
    *height = 1;
    return TRUE;
  }
  // 直接把 front 交出去：它在下一次 set_frame 时会被换出（指针交换），
  // 不会被原地改写，因此 Flutter 采样期间内容稳定。
  *out_buffer = self->front;
  *width = self->width;
  *height = self->height;
  g_mutex_unlock(&self->mutex);
  return TRUE;
}

static void hein_sw_texture_class_init(HeinSwTextureClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = hein_sw_texture_finalize;
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      hein_sw_texture_copy_pixels;
}

static void hein_sw_texture_init(HeinSwTexture* self) {
  g_mutex_init(&self->mutex);
  self->front = NULL;
  self->back = NULL;
  self->width = 0;
  self->height = 0;
  self->has_frame = FALSE;
}

HeinSwTexture* hein_sw_texture_new(void) {
  return HEIN_SW_TEXTURE(g_object_new(HEIN_TYPE_SW_TEXTURE, NULL));
}

gboolean hein_sw_texture_set_frame(HeinSwTexture* self, const uint8_t* src,
                                   uint32_t width, uint32_t height,
                                   size_t stride) {
  if (self == NULL || src == NULL || width == 0 || height == 0) return FALSE;
  const size_t row_bytes = (size_t)width * 4;
  if (stride < row_bytes) stride = row_bytes;  // 兜底：紧凑排布

  const gsize need = row_bytes * height;
  g_mutex_lock(&self->mutex);
  if (self->width != width || self->height != height ||
      self->back == NULL) {
    g_free(self->back);
    self->back = g_malloc(need);
    self->width = width;
    self->height = height;
    // 尺寸变化时 front 也必须重建（旧 front 尺寸不匹配）
    g_free(self->front);
    self->front = g_malloc(need);
    memset(self->front, 0, need);
  }
  // 逐行拷贝：src 的行跨度为 stride，目标按紧凑 width*4 存
  // （copy_pixels 返回给 Flutter 时用紧凑排布，Flutter 按 width*4 解读）。
  for (uint32_t y = 0; y < height; ++y) {
    memcpy(self->back + (size_t)y * row_bytes, src + (size_t)y * stride,
           row_bytes);
  }
  // 指针交换：back 成为新的 front，旧 front 复用为下次的 back。
  uint8_t* tmp = self->front;
  self->front = self->back;
  self->back = tmp;
  self->has_frame = TRUE;
  g_mutex_unlock(&self->mutex);
  return TRUE;
}

void hein_sw_texture_mark_available(HeinSwTexture* self,
                                    FlTextureRegistrar* registrar) {
  if (self == NULL || registrar == NULL) return;
  fl_texture_registrar_mark_texture_frame_available(registrar,
                                                    FL_TEXTURE(self));
}

gboolean hein_sw_texture_has_frame(HeinSwTexture* self) {
  if (self == NULL) return FALSE;
  g_mutex_lock(&self->mutex);
  const gboolean r = self->has_frame;
  g_mutex_unlock(&self->mutex);
  return r;
}
