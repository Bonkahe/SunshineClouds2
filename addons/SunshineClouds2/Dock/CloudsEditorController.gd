@tool
extends Control
class_name CloudsEditorController

@export_category("Driver Tools")
@export var CloudsStatusLabel : Label
@export var CloudsActiveToggle : CheckButton
@export var CloudsDriverRefresh : Button
@export var CloudsDriverAccordianButton : AccordionButton
@export_category("Mask Tools")
@export var UseMaskToggle : CheckButton
@export var MaskStatusLabel : Label
@export var MaskFilePath : LineEdit
@export var MaskResolution : SpinBox
@export var MaskWidth : SpinBox
@export_category("Draw Tools")
@export var DrawWeightEnable : TextureButton
@export var DrawColorEnable : TextureButton
@export var DrawColorPicker : ColorPicker

@export var DrawTools : Control
@export var DrawSharpness : HSlider
@export var DrawStrength : HSlider

@export var compute_shader : RDShaderFile
@export var DrawingColor : Color
@export var InvertedDrawingColor : Color

@export_range(100,50000,50) var DefaultBrushSize : float = 1000.0
@export_range(100,50000,50) var DefaultCloudsHeight : float = 2000.0

var driver : SunshineCloudsDriverGD

var currentRoot : Node

var currentDrawingMask : RID = RID()

enum DRAWINGMODE {none, weight, color, setValue}

var drawScale : float
var currentCloudsHeight : float
var currentDrawMode : DRAWINGMODE = DRAWINGMODE.none
var drawingCurrently : bool = false
var drawInverted : bool = false
var drawBrushToolMaterial : BaseMaterial3D = preload("res://addons/SunshineClouds2/Dock/Materials/DrawBrushToolsMaterial.tres")
var drawBrushToolPrefab : PackedScene = preload("res://addons/SunshineClouds2/Dock/CloudsDrawBrush.tscn")
var drawBrushTool : MeshInstance3D

#region Compute Variables
var computeEnabled : bool = false
var rd : RenderingDevice
var shader : RID = RID()
var pipeline : RID = RID()

var uniform_set : RID
var push_constants : PackedByteArray

var last_image_data : PackedByteArray = []
#endregion

var pause_updates : bool = false


func _enter_tree() -> void:
	drawScale = DefaultBrushSize

func _notification(what):
	if what == NOTIFICATION_PREDELETE and is_instance_valid(self):
		RenderingServer.call_on_render_thread(ClearCompute)

func _process(delta: float) -> void:
	
	if (currentDrawMode != DRAWINGMODE.none):
		
		var selection = EditorInterface.get_selection()
		if (selection.get_selected_nodes().size() == 0):
			if (driver != null):
				selection.add_node(driver)
		
		if (currentDrawMode == DRAWINGMODE.color):
			drawBrushToolMaterial.albedo_color = DrawColorPicker.color
		
		if (drawingCurrently):
			
			RenderingServer.call_on_render_thread(ExecuteCompute.bindv([delta, false, Color.WHITE]))

func InitialSceneLoad() -> void:
	var sceneRoot = await FindSceneNode()
	SceneChanged(sceneRoot)

func RefreshSceneNode() -> void:
	var sceneRoot = await FindSceneNode()
	
	SceneChanged(sceneRoot)

func FindSceneNode() -> Node:
	var editorInterface = EditorPlugin.new().get_editor_interface()
	var sceneRoot = editorInterface.get_edited_scene_root()
	var iterationcount: int = 300 #30 seconds of checking.
	while sceneRoot == null && iterationcount > 0:
		await get_tree().create_timer(0.1).timeout
		iterationcount -= 1
		sceneRoot = editorInterface.get_edited_scene_root()
	
	return sceneRoot

func SceneChanged(scene_root : Node):
	
	pause_updates = true
	DrawWeightEnable.button_pressed = false
	DrawColorEnable.button_pressed = false
	last_image_data = []
	DisableDrawMode()
	
	currentRoot = scene_root
	driver = RetrieveCloudsDriver(scene_root)
	if (driver != null && driver.clouds_resource != null):
		driver.clouds_resource.maskDrawnRid = RID()
		
		MaskWidth.value = driver.clouds_resource.mask_width_km
		UseMaskToggle.button_pressed = driver.clouds_resource.extra_large_used_as_mask
	
	if ResourceLoader.exists(MaskFilePath.text):
		var image = ResourceLoader.load(MaskFilePath.text) as Image
		if image:
			print("retrieved mask scale")
			MaskResolution.value = image.get_width()
	pause_updates = false
	UpdateStatusDisplay()

func RetrieveCloudsDriver(scene_root : Node) -> SunshineCloudsDriverGD:
	if (scene_root != null):
		for child in scene_root.get_children():
			if child is SunshineCloudsDriverGD:
				return child
			
			var newDriver = RetrieveCloudsDriver(child)
			if (newDriver):
				return newDriver
	
	return null

func UpdateStatusDisplay():
	
	if (driver != null):
		CloudsActiveToggle.disabled = false
		CloudsActiveToggle.button_pressed = driver.update_continuously
		CloudsDriverRefresh.visible = false
		CloudsStatusLabel.text = "Clouds present"
		
		if ResourceLoader.exists(MaskFilePath.text):
			MaskStatusLabel.text = "Mask Detected: " + MaskFilePath.text
			DrawTools.visible = true
		else:
			MaskStatusLabel.text = "Mask Not Found."
			DrawTools.visible = false
		
	else:
		CloudsActiveToggle.disabled = true
		CloudsActiveToggle.button_pressed = false
		CloudsDriverRefresh.visible = true
		DrawTools.visible = false
		CloudsDriverAccordianButton.Open()
		CloudsStatusLabel.text = "Clouds not present"
	
	
	if driver != null && driver.clouds_resource != null:
		UseMaskToggle.disabled = false
	else:
		UseMaskToggle.disabled = true
		UseMaskToggle.button_pressed = false
	

func UpdateMaskSettings():
	if (pause_updates):
		return
	print("Update mask settings")
	if (driver != null && driver.clouds_resource != null):
		driver.clouds_resource.mask_width_km = MaskWidth.value
		driver.clouds_resource.extra_large_used_as_mask = UseMaskToggle.button_pressed
		if (!UseMaskToggle.button_pressed):
			driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load("res://addons/SunshineClouds2/NoiseTextures/ExtraLargeScaleNoise.tres")
		elif ResourceLoader.exists(MaskFilePath.text):
			driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load(MaskFilePath.text)
	
	InitializeMaskTexture()

func InitializeMaskTexture():
	#if (driver == null):
		#return
	
	if not rd:
		rd = RenderingServer.get_rendering_device()
		if not rd:
			return
	#currentDrawingMask = driver.clouds_resource.mask_rid
	#var useDriverData : bool = driver != null && driver.clouds_resource != null
	#
	print("initializing mask")
	if ResourceLoader.exists(MaskFilePath.text):
		print("loading mask")
		var image = ResourceLoader.load(MaskFilePath.text) as CompressedTexture2D
		if (!image || image.get_width() != MaskResolution.value):
			print(MaskFilePath.text)
			print("mask incorrect size found size:",  image.get_width(), " desired:", MaskResolution.value)
			image = Image.create(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF)
			image.clear_mipmaps()
			image.save_exr(MaskFilePath.text)
			
			var editorFileSystem := EditorInterface.get_resource_filesystem()
			editorFileSystem.scan()
	else:
		var image = Image.create(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF)
		image.clear_mipmaps()
		image.save_exr(MaskFilePath.text)
		
		var editorFileSystem := EditorInterface.get_resource_filesystem()
		editorFileSystem.scan()
	
	
	
	#driver.clouds_resource.mask_rid = currentDrawingMask
	#driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load(MaskFilePath.text)
	#driver.clouds_resource.last_size = Vector2i.ZERO
	
	RenderingServer.call_on_render_thread(InitializeCompute)
	call_deferred("UpdateStatusDisplay")

#region Draw mode

#region Compute

func InitializeCompute():
	computeEnabled = false
	#if driver == null:
		#return
	
	#currentDrawingMask = driver.clouds_resource.mask_rid
	#if !currentDrawingMask.is_valid():
		#return
	
	if not rd:
		rd = RenderingServer.get_rendering_device()
		if not rd:
			computeEnabled = false
			printerr("No rendering device on load.")
			return
	ClearCompute()
	if not compute_shader:
		compute_shader = ResourceLoader.load("res://addons/SunshineClouds2/Dock/MaskDrawingCompute.glsl")
	
	if not compute_shader:
		computeEnabled = false
		printerr("No Shader found for drawing tool.")
		ClearCompute()
		return
	
	var shader_spirv = compute_shader.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	if shader.is_valid():
		pipeline = rd.compute_pipeline_create(shader)
	else:
		computeEnabled = false
		printerr("Shader failed to compile.")
		ClearCompute()
		return
	
	var uniforms_array : Array[RDUniform] = []
	
	var newFormat : RDTextureFormat = RDTextureFormat.new()
	newFormat.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	newFormat.height = MaskResolution.value
	newFormat.width = MaskResolution.value
	newFormat.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var image : Image
	if ResourceLoader.exists(MaskFilePath.text):
		image = (ResourceLoader.load(MaskFilePath.text) as CompressedTexture2D).get_image()
	
	if image == null:
		image = Image.create(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF)

	currentDrawingMask = rd.texture_create(newFormat, RDTextureView.new(), [image.get_data()])
	
	if (driver != null && driver.clouds_resource != null):
		driver.clouds_resource.update_mask(currentDrawingMask)
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 0
	mask_uniform.add_id(currentDrawingMask)
	uniforms_array.append(mask_uniform)
	
	uniform_set = rd.uniform_set_create(uniforms_array, shader, 0)
	computeEnabled = true

func ClearCompute():
	if rd:
		if shader.is_valid():
			rd.free_rid(shader)
		shader = RID()
		
		if currentDrawingMask.is_valid():
			rd.free_rid(currentDrawingMask)
		currentDrawingMask = RID()

func ExecuteCompute(delta : float, setvalue : bool, setvalueColor : Color):
	if (!computeEnabled):
		return
	
	var resolution : float = MaskResolution.value
	var drawPosition : Vector2 = Vector2.ZERO
	var drawRadius = 0.0
	
	if (!setvalue):
		drawPosition = Vector2(drawBrushTool.global_position.x, drawBrushTool.global_position.z) 
		drawPosition = (drawPosition / (MaskWidth.value * 1000.0)) * resolution
		drawPosition += Vector2(resolution * 0.5, resolution * 0.5)
		
		drawRadius = (drawBrushTool.scale.x / (MaskWidth.value * 1000.0)) * resolution
	
	var groups = ceil(resolution / 32) + 1
	var drawSharpness = DrawSharpness.value
	var drawStrength = DrawStrength.value * delta
	if (drawInverted):
		drawStrength = -drawStrength
	
	var editingtype : float = 0.0
	if setvalue:
		editingtype = 2.0
	elif currentDrawMode == DRAWINGMODE.color:
		editingtype = 1.0
	
	var ms = StreamPeerBuffer.new()
	ms.put_float(drawPosition.x)
	ms.put_float(drawPosition.y)
	ms.put_float(drawRadius)
	ms.put_float(drawSharpness)
	
	ms.put_float(drawStrength)
	ms.put_float(editingtype)
	ms.put_float(resolution)
	ms.put_float(0.0)
	
	if (setvalue):
		ms.put_float(setvalueColor.r)
		ms.put_float(setvalueColor.g)
		ms.put_float(setvalueColor.b)
		ms.put_float(setvalueColor.a)
	else:
		ms.put_float(DrawColorPicker.color.r)
		ms.put_float(DrawColorPicker.color.g)
		ms.put_float(DrawColorPicker.color.b)
		ms.put_float(0.0)
	
	push_constants = ms.get_data_array()
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	
	
	await RenderingServer.frame_post_draw
	
	rd.texture_get_data_async(currentDrawingMask, 0, CompleteRetreval)

func CompleteRetreval(data):
	last_image_data = data
	#for byte in data:
		#print(byte)
	#print("RetrevalComplete ", data)
	#var image = Image.create_from_data(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF, data)
	##rd.texture_update(RenderingServer.texture_get_rd_texture(currentMask.get_rid()),0, data)
	#image.save_png(MaskFilePath.text)
	
	#var editorFileSystem := EditorInterface.get_resource_filesystem()
	#editorFileSystem.scan()

#endregion

func IterateCursorLocation(viewport_camera: Camera3D, event:InputEventMouse):
	if (is_instance_valid(driver) && driver.clouds_resource != null):
		currentCloudsHeight = (driver.clouds_resource.cloud_floor + driver.clouds_resource.cloud_ceiling) / 2.0
	else:
		currentCloudsHeight = DefaultCloudsHeight
	var ray_origin = viewport_camera.project_ray_origin(event.position)
	var ray_dir = viewport_camera.project_ray_normal(event.position)
	
	var result : float = RetrieveTravelDistance(ray_origin, ray_dir)
	if (result == -1.0):
		drawBrushTool.visible = false
	else:
		drawBrushTool.visible = true
		drawBrushTool.global_position = ray_origin + ray_dir * result
		drawBrushTool.global_position.y = driver.clouds_resource.cloud_floor

func BeginCursorDraw():
	drawingCurrently = true

func EndCursorDraw():
	drawingCurrently = false

func ScaleDrawingCircleUp():
	drawScale = min(drawScale + (drawScale * 0.1), 100000.0)
	SetDrawScale()

func ScaleDrawingCircleDown():
	drawScale = max(drawScale - (drawScale * 0.1), 100.0)
	SetDrawScale()

func DrawModeCancel():
	DrawWeightEnable.button_pressed = false
	DrawColorEnable.button_pressed = false
	DisableDrawMode()
	

func SetDrawScale():
	if driver != null && driver.clouds_resource != null:
		drawBrushTool.scale = Vector3(drawScale, driver.clouds_resource.cloud_ceiling - driver.clouds_resource.cloud_floor, drawScale)
	else:
		drawBrushTool.scale = Vector3(drawScale, 1000.0, drawScale)

#region Draw Mode Toggles

func FloodFill():
	var resultColor : Color = DrawColorPicker.color
	resultColor.a = DrawStrength.value / DrawStrength.max_value
	RenderingServer.call_on_render_thread(ExecuteCompute.bindv([0.0, true, resultColor]))
	await get_tree().create_timer(0.2).timeout
	call_deferred("DisableDrawMode")

func DrawWeightToggled():
	DrawColorEnable.button_pressed = false
	
	if DrawWeightEnable.button_pressed && EnableDrawMode():
		currentDrawMode = DRAWINGMODE.weight
	else:
		DrawWeightEnable.button_pressed = false

func DrawColorToggled():
	DrawWeightEnable.button_pressed = false
	
	if DrawColorEnable.button_pressed && EnableDrawMode():
		currentDrawMode = DRAWINGMODE.color
	else:
		DrawColorEnable.button_pressed = false

func EnableDrawMode() -> bool:
	if (!computeEnabled):
		InitializeMaskTexture()
	
	if (!is_instance_valid(currentRoot)):
		return false
	drawBrushToolMaterial.albedo_color = DrawingColor
	if (!is_instance_valid(drawBrushTool)):
		drawBrushTool = drawBrushToolPrefab.instantiate() as MeshInstance3D
		currentRoot.add_child(drawBrushTool)
		SetDrawScale()
	
	return true

func DisableDrawMode():
	DrawColorEnable.button_pressed = false
	DrawWeightEnable.button_pressed = false
	currentDrawMode = DRAWINGMODE.none
	drawInverted = false
	if (drawingCurrently):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		drawingCurrently = false
	
	if (is_instance_valid(drawBrushTool)):
		drawBrushTool.queue_free()
		drawBrushTool = null
	
	if (last_image_data.size() > 0):
		print("Saved image to disc")
		var image = Image.create_from_data(MaskResolution.value, MaskResolution.value, false, Image.FORMAT_RGBAF, last_image_data)
		
		image.save_exr(MaskFilePath.text)
		var editorFileSystem := EditorInterface.get_resource_filesystem()
		editorFileSystem.scan()
		
		last_image_data = []
		
		if (driver != null && driver.clouds_resource != null):
			driver.clouds_resource.extra_large_noise_patterns = ResourceLoader.load(MaskFilePath.text)

#endregion

func SetDrawInvert(mode : bool):
	if (currentDrawMode == DRAWINGMODE.weight && drawInverted != mode):
		drawInverted = mode
		drawBrushToolMaterial.albedo_color = InvertedDrawingColor if drawInverted else DrawingColor


#region draw tools helpers

func RetrieveTravelDistance(pos : Vector3, dir :Vector3) -> float:
	var t : float = (currentCloudsHeight - pos.y) / dir.y
	if (dir.y == 0 || t < 0.0):
		return -1.0
	
	
	return t * dir.length()

#endregion

#endregion

#Updates
func SetCloudsUpdating():
	if (driver != null):
		driver.update_continuously = CloudsActiveToggle.button_pressed
	
	UpdateStatusDisplay()


#
#
#
#
#@tool
#extends MeshInstance3D
#class_name WanderingTerrainDrawnStamp
#
#
#@export var visibleColorMat : ShaderMaterial = preload("res://addons/WanderingTerrain/Materials/StampMaterials/EraseChunkVisibleColorMat.tres")
#@export var highlightedColorMat : ShaderMaterial = preload("res://addons/WanderingTerrain/Materials/StampMaterials/EraseChunkHighlightedColorMat.tres")
#@export var thisStampIndex : Vector2
#@export var currentHeightmapImageTexture: Texture2D
#@export var currentColormapImageTexture: Texture2D
#@export var currentSplatmapImageTexture: Texture2D
#@export var currentMaterial : ShaderMaterial
#
#var newHeightmapImage : Image
#var newColormapImage : Image
#var newSplatmapImage : Image
#var newHeightmapdrawingDirty : bool = false
#var newColormapdrawingDirty : bool = false
#var newSplatmapdrawingDirty : bool = false
#var pixelChanged : bool = false
#
#enum DrawingUpdateMode {sculpting, colorpainting, splatpainting}
#
#var thisRect : Rect2
#
#
#func InitializeDrawnStamp(resolution : int, indexPosition : Vector2, position : Vector3, currentUpdateType : DrawingUpdateMode):
	#add_to_group("WanderingTerrainSculptingStamps", true);
	#thisStampIndex = indexPosition
	#global_position = position
	#currentMaterial = material_override.duplicate()
	#material_override = currentMaterial
	#
	#UpdateDrawnStamp(resolution, currentUpdateType)
#
#func SetVisible():
	#currentMaterial.next_pass = visibleColorMat
#
#func SetHidden():
	#currentMaterial.next_pass = null
#
#func Highlight():
	#currentMaterial.next_pass = highlightedColorMat
#
#func Unhightlight():
	#currentMaterial.next_pass = visibleColorMat
#
#func CheckHasAnyUpdate() -> bool:
	#
	#if (pixelChanged || currentHeightmapImageTexture != null || currentColormapImageTexture != null || currentSplatmapImageTexture != null):
		#return true
	#
	#return false
#
#func UpdateDrawnStamp(resolution : int, currentUpdateType : DrawingUpdateMode):
	#
	#match currentUpdateType:
		#DrawingUpdateMode.sculpting:
			#
			#if (newHeightmapImage == null || newHeightmapImage.get_width() != resolution):
				#if (currentHeightmapImageTexture != null && currentHeightmapImageTexture.get_width() == resolution):
					#newHeightmapImage = currentHeightmapImageTexture.get_image()
				#else:
					#currentHeightmapImageTexture = null
					#newHeightmapdrawingDirty = true
					#newHeightmapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGF)
					#for x in resolution:
						#for y in resolution:
							#newHeightmapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#
			#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
			#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
		#
		#DrawingUpdateMode.colorpainting:
			#
			#if (newColormapImage == null || newColormapImage.get_width() != resolution):
				#if (currentColormapImageTexture != null && currentColormapImageTexture.get_width() == resolution):
					#newColormapImage = currentColormapImageTexture.get_image()
				#else:
					#currentColormapImageTexture = null
					#newColormapdrawingDirty = true
					#newColormapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
					#for x in resolution:
						#for y in resolution:
							#newColormapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#var imageTexture = ImageTexture.create_from_image(newColormapImage)
			#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
			#currentMaterial.set_shader_parameter("HasColorMap", true);
		#
		#DrawingUpdateMode.splatpainting:
			#
			#if (newSplatmapImage == null || newSplatmapImage.get_width() != resolution):
				#if (currentSplatmapImageTexture != null && currentSplatmapImageTexture.get_width() == resolution):
					#newSplatmapImage = currentSplatmapImageTexture.get_image()
				#else:
					#currentSplatmapImageTexture = null
					#newSplatmapdrawingDirty = true
					#newSplatmapImage = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
					#for x in resolution:
						#for y in resolution:
							#newSplatmapImage.set_pixel(x,y, Color(0.0,0.0,0.0,0.0))
			#
			#var imageTexture = ImageTexture.create_from_image(newSplatmapImage)
			#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
			#currentMaterial.set_shader_parameter("HasSplatMap", true);
	#
	#
	#thisRect = Rect2(Vector2(global_position.x - resolution / 2, global_position.z - resolution / 2),Vector2(resolution, resolution))
#
#func IsInsideRect(targetPosition : Vector2, stampRadius : float) -> bool:
	#if thisRect.has_point(targetPosition) || thisRect.has_point(targetPosition + (Vector2(global_position.x, global_position.z) - targetPosition).normalized() * stampRadius):
		#return true
	#return false
#
#
#
#func PackStamp(terrainController : WanderingTerrainController):
	#if (newHeightmapdrawingDirty && newHeightmapImage != null):
		#newHeightmapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newHeightmapImage, name + "_height_savedstamp", "exr")
		#if (resultingResource != null):
			#currentHeightmapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("HeightMap", currentHeightmapImageTexture)
	#
	#if (newColormapdrawingDirty && newColormapImage != null):
		#newColormapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newColormapImage, name + "_color_savedstamp", "exr")
		#if (resultingResource != null):
			#currentColormapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("ColorMap", currentColormapImageTexture)
	#
	#if (newSplatmapdrawingDirty && newSplatmapImage != null):
		#newSplatmapdrawingDirty = false
		#var resultingResource = await terrainController.Editor_SaveImageToOutputFolder(newSplatmapImage, name + "_splatmap_savedstamp", "exr")
		#if (resultingResource != null):
			#currentSplatmapImageTexture = resultingResource
			#currentMaterial.set_shader_parameter("SplatMap", currentSplatmapImageTexture)
#
#func ColorPainting_DrawOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, color : Color, layer : DrawingUpdateMode):
	#var localPosition : Vector3 = targetPosition - global_position
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#var currentImage : Image
	#if (layer == DrawingUpdateMode.colorpainting):
		#newColormapdrawingDirty = true
		#currentImage = newColormapImage
	#else:
		#newSplatmapdrawingDirty = true
		#currentImage = newSplatmapImage
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= currentImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= currentImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = currentImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#if (thisColor.a == 0):
				#thisColor.r = color.r
				#thisColor.g = color.g 
				#thisColor.b = color.b
			#
			#thisColor.r = lerpf(thisColor.r, color.r, stampAlpha * power * 0.2)
			#thisColor.g = lerpf(thisColor.g, color.g, stampAlpha * power * 0.2)
			#thisColor.b = lerpf(thisColor.b, color.b, stampAlpha * power * 0.2)
			#
			### Handles opacity, which always goes up.
			#thisColor.a = clampf(thisColor.a + (stampAlpha * abs(power) * 0.2), 0.0, 1.0)
			#currentImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(currentImage)
	#
	#if (layer == DrawingUpdateMode.colorpainting):
		#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
		#newColormapImage = currentImage
	#else:
		#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
		#newSplatmapImage = currentImage
#
#func ColorPainting_EraseOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, layer : DrawingUpdateMode):
	#var localPosition : Vector3 = targetPosition - global_position
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#var currentImage : Image
	#if (layer == DrawingUpdateMode.colorpainting):
		#newColormapdrawingDirty = true
		#currentImage = newColormapImage
	#else:
		#newSplatmapdrawingDirty = true
		#currentImage = newSplatmapImage
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= currentImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= currentImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = currentImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#thisColor.a = clampf(thisColor.a - stampAlpha * power * 0.2, 0.0, 1.0)
			#
			#currentImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
	#
	#var imageTexture = ImageTexture.create_from_image(currentImage)
	#
	#if (layer == DrawingUpdateMode.colorpainting):
		#currentMaterial.set_shader_parameter("ColorMap", imageTexture)
		#newColormapImage = currentImage
	#else:
		#currentMaterial.set_shader_parameter("SplatMap", imageTexture)
		#newSplatmapImage = currentImage
#
#func Sculpt_EraseOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			##thisColor.r += (0.5 - thisColor.r) * stampAlpha * power * 0.2
			#thisColor.g = clampf(thisColor.g - stampAlpha * power * 0.2, 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#func Sculpt_SmoothOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var heightValue : float = clamp((targetPosition.y) / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#thisColor.r = clampf(thisColor.r + ((heightValue - thisColor.r) * stampAlpha * power * 0.2), 0.0, 1.0)
			#thisColor.g = clampf(thisColor.g + ((0.0 - thisColor.g) * stampAlpha * power * 0.05), 0.0, 1.0)
			#
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#
#func Sculpt_DrawOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var heightValue = clamp(targetPosition.y / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			### Handles actual value.
			#if (thisColor.g == 0):
				#thisColor.r = heightValue
			#thisColor.r = clampf(thisColor.r + (stampAlpha * power * 0.05), 0.0, 1.0)
			### Handles opacity, which always goes up.
			#thisColor.g = clampf(thisColor.g + (stampAlpha * abs(power) * 0.05), 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
#
#func Sculpt_SetHeightOnImage(targetPosition : Vector3, stampRadius : float, stampImage : Image, heightValue : float, power : float, worldScale : float):
	#newHeightmapdrawingDirty = true
	#
	#var localPosition : Vector3 = targetPosition - global_position
	#
	#var localPositionPixelSpace := Vector2(localPosition.x + 256, localPosition.z + 256)
	#var stampScale : float = stampImage.get_width() / stampRadius
	#var stampActualResolution : float = (stampImage.get_width() / stampScale) + 1
	#
	#var stampPos : Vector2 = Vector2(localPositionPixelSpace.x, localPositionPixelSpace.y)
	#var stampTopCornerPos : Vector2 = Vector2(localPositionPixelSpace.x - stampActualResolution / 2, localPositionPixelSpace.y - stampActualResolution / 2 )
	#var currentPos : Vector2
	#var thisColor: Color
	#var stampAlpha: float
	#var currentHeight = clamp(targetPosition.y / worldScale, 0.0, 1.0)
	#heightValue = clamp(heightValue / worldScale, 0.0, 1.0)
	#var hasNoAlpha = stampImage.detect_alpha() == Image.ALPHA_NONE
	#
	#for x in stampActualResolution:
		#if (stampTopCornerPos.x + x >= newHeightmapImage.get_width() || x * stampScale >= stampImage.get_width()):
			#break
		#for y in stampActualResolution:
			#if (stampTopCornerPos.y + y >= newHeightmapImage.get_height() || y * stampScale >= stampImage.get_width()):
				#break
			#currentPos.x = stampTopCornerPos.x + x
			#currentPos.y = stampTopCornerPos.y + y
			#if (currentPos.x < 0 || currentPos.y < 0):
				#continue
			#
			#thisColor = newHeightmapImage.get_pixelv(currentPos)
			#if (hasNoAlpha):
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).r
			#else:
				#stampAlpha = stampImage.get_pixel(x * stampScale,y * stampScale).a
			#
			#if (thisColor.g == 0):
				#thisColor.r = currentHeight
			#
			#thisColor.r = clampf(thisColor.r + ((heightValue - thisColor.r) * stampAlpha * power), 0.0, 1.0)
			### Handles opacity, which always goes up.
			#thisColor.g = clampf(thisColor.g + (stampAlpha * abs(power) * 0.2), 0.0, 1.0)
			#newHeightmapImage.set_pixel(currentPos.x, currentPos.y, thisColor) 
			#pixelChanged = true
	#
	#var imageTexture = ImageTexture.create_from_image(newHeightmapImage)
	#
	#currentMaterial.set_shader_parameter("HeightMap", imageTexture)
