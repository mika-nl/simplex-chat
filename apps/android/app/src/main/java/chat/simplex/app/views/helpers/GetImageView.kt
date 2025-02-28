package chat.simplex.app.views.helpers

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.*
import android.net.Uri
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.widget.Toast
import androidx.activity.compose.ManagedActivityResultLauncher
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.CallSuper
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Collections
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import chat.simplex.app.*
import chat.simplex.app.R
import chat.simplex.app.views.newchat.ActionButton
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.min
import kotlin.math.sqrt

// Inspired by https://github.com/MakeItEasyDev/Jetpack-Compose-Capture-Image-Or-Choose-from-Gallery

fun cropToSquare(image: Bitmap): Bitmap {
  var xOffset = 0
  var yOffset = 0
  val side = min(image.height, image.width)
  if (image.height < image.width) {
    xOffset = (image.width - side) / 2
  } else {
    yOffset = (image.height - side) / 2
  }
  return Bitmap.createBitmap(image, xOffset, yOffset, side, side)
}

fun resizeImageToDataSize(image: Bitmap, maxDataSize: Int): String {
  var img = image
  var str = compressImage(img)
  while (str.length > maxDataSize) {
    val ratio = sqrt(str.length.toDouble() / maxDataSize.toDouble())
    val clippedRatio = min(ratio, 2.0)
    val width = (img.width.toDouble() / clippedRatio).toInt()
    val height = img.height * width / img.width
    img = Bitmap.createScaledBitmap(img, width, height, true)
    str = compressImage(img)
  }
  return str
}

private fun compressImage(bitmap: Bitmap): String {
  val stream = ByteArrayOutputStream()
  bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)
  return "data:image/jpg;base64," + Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
}

fun base64ToBitmap(base64ImageString: String) : Bitmap {
  val imageString = base64ImageString
    .removePrefix("data:image/png;base64,")
    .removePrefix("data:image/jpg;base64,")
  val imageBytes = Base64.decode(imageString, Base64.NO_WRAP)
  return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
}

class CustomTakePicturePreview : ActivityResultContract<Void?, Bitmap?>() {
  private var uri: Uri? = null
  private var tmpFile: File? = null
  lateinit var externalContext: Context

  @CallSuper
  override fun createIntent(context: Context, input: Void?): Intent {
    externalContext = context
    tmpFile = File.createTempFile("image", ".bmp", context.filesDir)
    uri = FileProvider.getUriForFile(context, "${BuildConfig.APPLICATION_ID}.provider", tmpFile!!)
    return Intent(MediaStore.ACTION_IMAGE_CAPTURE)
      .putExtra(MediaStore.EXTRA_OUTPUT, uri)
  }

  override fun getSynchronousResult(
    context: Context,
    input: Void?
  ): SynchronousResult<Bitmap?>? = null

  override fun parseResult(resultCode: Int, intent: Intent?): Bitmap? {
    return if (resultCode == Activity.RESULT_OK && uri != null) {
      val source = ImageDecoder.createSource(externalContext.contentResolver, uri!!)
      val bitmap = ImageDecoder.decodeBitmap(source)
      tmpFile?.delete()
      bitmap
    } else {
      Log.e( TAG, "Getting image from camera cancelled or failed.")
      tmpFile?.delete()
      null
    }
  }
}

@Composable
fun rememberGalleryLauncher(cb: (Uri?) -> Unit): ManagedActivityResultLauncher<String, Uri?> =
  rememberLauncherForActivityResult(contract = ActivityResultContracts.GetContent(), cb)

@Composable
fun rememberCameraLauncher(cb: (Bitmap?) -> Unit): ManagedActivityResultLauncher<Void?, Bitmap?> =
  rememberLauncherForActivityResult(contract = CustomTakePicturePreview(), cb)

@Composable
fun rememberPermissionLauncher(cb: (Boolean) -> Unit): ManagedActivityResultLauncher<String, Boolean> =
  rememberLauncherForActivityResult(contract = ActivityResultContracts.RequestPermission(), cb)

@Composable
fun GetImageBottomSheet(
  imageBitmap: MutableState<Bitmap?>,
  onImageChange: (Bitmap) -> Unit,
  hideBottomSheet: () -> Unit
) {
  val context = LocalContext.current
  val isCameraSelected = remember { mutableStateOf (false) }

  val galleryLauncher = rememberGalleryLauncher { uri: Uri? ->
    if (uri != null) {
      val source = ImageDecoder.createSource(context.contentResolver, uri)
      val bitmap = ImageDecoder.decodeBitmap(source)
      imageBitmap.value = bitmap
      onImageChange(bitmap)
    }
  }

  val cameraLauncher = rememberCameraLauncher { bitmap: Bitmap? ->
    if (bitmap != null) {
      imageBitmap.value = bitmap
      onImageChange(bitmap)
    }
  }

  val permissionLauncher = rememberPermissionLauncher { isGranted: Boolean ->
    if (isGranted) {
      if (isCameraSelected.value) cameraLauncher.launch(null)
      else galleryLauncher.launch("image/*")
      hideBottomSheet()
    } else {
      Toast.makeText(context, generalGetString(R.string.toast_camera_permission_denied), Toast.LENGTH_SHORT).show()
    }
  }

  Box(
    modifier = Modifier
      .fillMaxWidth()
      .wrapContentHeight()
      .onFocusChanged { focusState ->
        if (!focusState.hasFocus) hideBottomSheet()
      }
  ) {
    Row(
      Modifier
        .fillMaxWidth()
        .padding(horizontal = 8.dp, vertical = 30.dp),
      horizontalArrangement = Arrangement.SpaceEvenly
    ) {
      ActionButton(null, generalGetString(R.string.use_camera_button), icon = Icons.Outlined.PhotoCamera) {
        when (PackageManager.PERMISSION_GRANTED) {
          ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) -> {
            cameraLauncher.launch(null)
            hideBottomSheet()
          }
          else -> {
            isCameraSelected.value = true
            permissionLauncher.launch(Manifest.permission.CAMERA)
          }
        }
      }
      ActionButton(null, generalGetString(R.string.from_gallery_button), icon = Icons.Outlined.Collections) {
        when (PackageManager.PERMISSION_GRANTED) {
          ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) -> {
            galleryLauncher.launch("image/*")
            hideBottomSheet()
          }
          else -> {
            isCameraSelected.value = false
            permissionLauncher.launch(Manifest.permission.READ_EXTERNAL_STORAGE)
          }
        }
      }
    }
  }
}
