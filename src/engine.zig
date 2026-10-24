const std = @import("std");
const c = @import("c");
const assets = @import("assets.zig");
const types = @import("types.zig");
const Vertex = types.Vertex;
const Push = types.Push;
const Sprite = types.Sprite;
const PixelViewport = types.PixelViewport;
const texture_mod = @import("texture.zig");
const Texture = texture_mod.Texture;
const renderer2d = @import("renderer2d.zig");

pub const MAX_FRAMES_IN_FLIGHT = 2;

pub const Engine = struct {
    window: ?*c.GLFWwindow,
    viewport: PixelViewport,
    allocator: std.mem.Allocator,

    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,

    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    graphics_family: u32 = 0,
    present_family: u32 = 0,

    swapchain: c.VkSwapchainKHR = null,
    swapchain_images: []c.VkImage = &.{},
    swapchain_image_views: []c.VkImageView = &.{},
    swapchain_framebuffers: []c.VkFramebuffer = &.{},
    swapchain_format: c.VkFormat = c.VK_FORMAT_B8G8R8A8_SRGB,
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    render_pass: c.VkRenderPass = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    pipeline_layout: c.VkPipelineLayout = null,
    graphics_pipeline: c.VkPipeline = null,
    descriptor_pool: c.VkDescriptorPool = null,

    command_pool: c.VkCommandPool = null,
    command_buffers: []c.VkCommandBuffer = &.{},

    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore = [_]c.VkSemaphore{ null, null },
    render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore = [_]c.VkSemaphore{ null, null },
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]c.VkFence = [_]c.VkFence{ null, null },
    current_frame: usize = 0,

    vertex_buffer: c.VkBuffer = null,
    vertex_buffer_memory: c.VkDeviceMemory = null,

    offscreen_tex: Texture = .{},
    offscreen_pass: c.VkRenderPass = null,
    offscreen_framebuffer: c.VkFramebuffer = null,

    framebuffer_resized: bool = false,

    pub fn init(allocator: std.mem.Allocator, window: ?*c.GLFWwindow, vw: i32, vh: i32) !*Engine {
        const self = try allocator.create(Engine);
        self.* = .{
            .window = window,
            .viewport = PixelViewport.init(vw, vh),
            .allocator = allocator,
        };

        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapChain();
        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipeline();
        try self.createDescriptorPool();
        try self.createFramebuffers();
        try self.createCommandPool();
        try self.createVertexBuffer();
        try self.createSyncObjects();
        try self.createRenderTarget();

        try texture_mod.init(allocator, @ptrCast(self), createTextureCallback, updateTextureCallback);

        return self;
    }

    fn createInstance(self: *Engine) !void {
        var count: u32 = 0;
        const glfw_extensions = c.glfwGetRequiredInstanceExtensions(&count);

        var app_info: c.VkApplicationInfo = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "dead10sec";
        app_info.applicationVersion = c.VK_MAKE_VERSION(1, 0, 0);
        app_info.pEngineName = "dead10sec";
        app_info.engineVersion = c.VK_MAKE_VERSION(1, 0, 0);
        app_info.apiVersion = c.VK_API_VERSION_1_1;

        var create_info: c.VkInstanceCreateInfo = std.mem.zeroes(c.VkInstanceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = count;
        create_info.ppEnabledExtensionNames = glfw_extensions;

        if (c.vkCreateInstance(&create_info, null, &self.instance) != c.VK_SUCCESS) {
            return error.VkInstanceCreateFailed;
        }
    }

    fn createSurface(self: *Engine) !void {
        if (c.glfwCreateWindowSurface(self.instance, self.window, null, &self.surface) != c.VK_SUCCESS) {
            return error.VkSurfaceCreateFailed;
        }
    }

    fn pickPhysicalDevice(self: *Engine) !void {
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr);

        for (devices) |device| {
            var q_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &q_count, null);
            const q_props = try self.allocator.alloc(c.VkQueueFamilyProperties, q_count);
            defer self.allocator.free(q_props);
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &q_count, q_props.ptr);

            var g_opt: ?u32 = null;
            var p_opt: ?u32 = null;

            for (q_props, 0..) |qp, i| {
                const idx: u32 = @intCast(i);
                if ((qp.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
                    g_opt = idx;
                }
                var present_support: c.VkBool32 = 0;
                _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, self.surface, &present_support);
                if (present_support != 0) {
                    p_opt = idx;
                }
                if (g_opt != null and p_opt != null) break;
            }

            if (g_opt != null and p_opt != null) {
                self.physical_device = device;
                self.graphics_family = g_opt.?;
                self.present_family = p_opt.?;
                return;
            }
        }

        return error.SuitableDeviceNotFound;
    }

    fn createLogicalDevice(self: *Engine) !void {
        const priority: f32 = 1.0;
        var queue_infos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;

        queue_infos[0] = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_infos[0].sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_infos[0].queueFamilyIndex = self.graphics_family;
        queue_infos[0].queueCount = 1;
        queue_infos[0].pQueuePriorities = &priority;

        if (self.graphics_family != self.present_family) {
            queue_infos[1] = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
            queue_infos[1].sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queue_infos[1].queueFamilyIndex = self.present_family;
            queue_infos[1].queueCount = 1;
            queue_infos[1].pQueuePriorities = &priority;
            queue_count = 2;
        }

        const extensions = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

        var device_features: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);

        var create_info: c.VkDeviceCreateInfo = std.mem.zeroes(c.VkDeviceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        create_info.queueCreateInfoCount = queue_count;
        create_info.pQueueCreateInfos = &queue_infos[0];
        create_info.pEnabledFeatures = &device_features;
        create_info.enabledExtensionCount = extensions.len;
        create_info.ppEnabledExtensionNames = &extensions;

        if (c.vkCreateDevice(self.physical_device, &create_info, null, &self.device) != c.VK_SUCCESS) {
            return error.VkDeviceCreateFailed;
        }

        c.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        c.vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);
    }

    fn createSwapChain(self: *Engine) !void {
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &caps);

        var format_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);
        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr);

        var chosen_format = formats[0];
        for (formats) |f| {
            if ((f.format == c.VK_FORMAT_B8G8R8A8_SRGB or f.format == c.VK_FORMAT_R8G8B8A8_SRGB) and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                chosen_format = f;
                break;
            }
        }
        self.swapchain_format = chosen_format.format;

        var extent: c.VkExtent2D = undefined;
        if (caps.currentExtent.width != std.math.maxInt(u32)) {
            extent = caps.currentExtent;
        } else {
            var w: c_int = 0;
            var h: c_int = 0;
            c.glfwGetFramebufferSize(self.window, &w, &h);
            extent = .{
                .width = std.math.clamp(@as(u32, @intCast(w)), caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(@as(u32, @intCast(h)), caps.minImageExtent.height, caps.maxImageExtent.height),
            };
        }
        self.swapchain_extent = extent;

        var img_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and img_count > caps.maxImageCount) {
            img_count = caps.maxImageCount;
        }

        var swap_info: c.VkSwapchainCreateInfoKHR = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        swap_info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        swap_info.surface = self.surface;
        swap_info.minImageCount = img_count;
        swap_info.imageFormat = chosen_format.format;
        swap_info.imageColorSpace = chosen_format.colorSpace;
        swap_info.imageExtent = extent;
        swap_info.imageArrayLayers = 1;
        swap_info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        const q_indices = [_]u32{ self.graphics_family, self.present_family };
        if (self.graphics_family != self.present_family) {
            swap_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swap_info.queueFamilyIndexCount = 2;
            swap_info.pQueueFamilyIndices = &q_indices;
        } else {
            swap_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        }

        swap_info.preTransform = caps.currentTransform;
        swap_info.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        swap_info.presentMode = c.VK_PRESENT_MODE_FIFO_KHR;
        swap_info.clipped = c.VK_TRUE;

        if (c.vkCreateSwapchainKHR(self.device, &swap_info, null, &self.swapchain) != c.VK_SUCCESS) {
            return error.VkSwapchainCreateFailed;
        }

        var actual_img_count: u32 = 0;
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_img_count, null);
        self.swapchain_images = try self.allocator.alloc(c.VkImage, actual_img_count);
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_img_count, self.swapchain_images.ptr);

        self.swapchain_image_views = try self.allocator.alloc(c.VkImageView, actual_img_count);
        for (self.swapchain_images, 0..) |img, i| {
            var view_info: c.VkImageViewCreateInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = img;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = self.swapchain_format;
            view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            view_info.subresourceRange.levelCount = 1;
            view_info.subresourceRange.layerCount = 1;
            if (c.vkCreateImageView(self.device, &view_info, null, &self.swapchain_image_views[i]) != c.VK_SUCCESS) {
                return error.VkImageViewCreateFailed;
            }
        }
    }

    fn createRenderPass(self: *Engine) !void {
        var color_attachment: c.VkAttachmentDescription = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = self.swapchain_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_ref: c.VkAttachmentReference = std.mem.zeroes(c.VkAttachmentReference);
        color_ref.attachment = 0;
        color_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var subpass: c.VkSubpassDescription = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency: c.VkSubpassDependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        var pass_info: c.VkRenderPassCreateInfo = std.mem.zeroes(c.VkRenderPassCreateInfo);
        pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        pass_info.attachmentCount = 1;
        pass_info.pAttachments = &color_attachment;
        pass_info.subpassCount = 1;
        pass_info.pSubpasses = &subpass;
        pass_info.dependencyCount = 1;
        pass_info.pDependencies = &dependency;

        if (c.vkCreateRenderPass(self.device, &pass_info, null, &self.render_pass) != c.VK_SUCCESS) {
            return error.VkRenderPassCreateFailed;
        }
    }

    fn createDescriptorSetLayout(self: *Engine) !void {
        var layout_binding: c.VkDescriptorSetLayoutBinding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        layout_binding.binding = 0;
        layout_binding.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        layout_binding.descriptorCount = 1;
        layout_binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var layout_info: c.VkDescriptorSetLayoutCreateInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 1;
        layout_info.pBindings = &layout_binding;

        if (c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layout) != c.VK_SUCCESS) {
            return error.VkDescriptorSetLayoutCreateFailed;
        }
    }

    fn createGraphicsPipeline(self: *Engine) !void {
        const vert_module = try self.createShaderModule(assets.shader_vert);
        defer c.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(assets.shader_frag);
        defer c.vkDestroyShaderModule(self.device, frag_module, null);

        var vert_stage: c.VkPipelineShaderStageCreateInfo = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        vert_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        vert_stage.stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        vert_stage.module = vert_module;
        vert_stage.pName = "main";

        var frag_stage: c.VkPipelineShaderStageCreateInfo = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        frag_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        frag_stage.stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        frag_stage.module = frag_module;
        frag_stage.pName = "main";

        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{ vert_stage, frag_stage };

        var binding_desc: c.VkVertexInputBindingDescription = std.mem.zeroes(c.VkVertexInputBindingDescription);
        binding_desc.binding = 0;
        binding_desc.stride = @sizeOf(Vertex);
        binding_desc.inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;

        var attr_descs: [2]c.VkVertexInputAttributeDescription = undefined;
        attr_descs[0] = std.mem.zeroes(c.VkVertexInputAttributeDescription);
        attr_descs[0].binding = 0;
        attr_descs[0].location = 0;
        attr_descs[0].format = c.VK_FORMAT_R32G32_SFLOAT;
        attr_descs[0].offset = @offsetOf(Vertex, "pos");

        attr_descs[1] = std.mem.zeroes(c.VkVertexInputAttributeDescription);
        attr_descs[1].binding = 0;
        attr_descs[1].location = 1;
        attr_descs[1].format = c.VK_FORMAT_R32G32_SFLOAT;
        attr_descs[1].offset = @offsetOf(Vertex, "uv");

        var vertex_input: c.VkPipelineVertexInputStateCreateInfo = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input.vertexBindingDescriptionCount = 1;
        vertex_input.pVertexBindingDescriptions = &binding_desc;
        vertex_input.vertexAttributeDescriptionCount = attr_descs.len;
        vertex_input.pVertexAttributeDescriptions = &attr_descs;

        var input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var viewport_state: c.VkPipelineViewportStateCreateInfo = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        var rasterizer: c.VkPipelineRasterizationStateCreateInfo = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.polygonMode = c.VK_POLYGON_MODE_FILL;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;

        var multisampling: c.VkPipelineMultisampleStateCreateInfo = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var color_blend_attachment: c.VkPipelineColorBlendAttachmentState = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        color_blend_attachment.blendEnable = c.VK_TRUE;
        color_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        color_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        color_blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        color_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        color_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        color_blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;

        var color_blending: c.VkPipelineColorBlendStateCreateInfo = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blending.attachmentCount = 1;
        color_blending.pAttachments = &color_blend_attachment;

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic_state: c.VkPipelineDynamicStateCreateInfo = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = dynamic_states.len;
        dynamic_state.pDynamicStates = &dynamic_states;

        var push_constant_range: c.VkPushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
        push_constant_range.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        push_constant_range.offset = 0;
        push_constant_range.size = @sizeOf(Push);

        var pipeline_layout_info: c.VkPipelineLayoutCreateInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &push_constant_range;

        if (c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout) != c.VK_SUCCESS) {
            return error.VkPipelineLayoutCreateFailed;
        }

        var pipeline_info: c.VkGraphicsPipelineCreateInfo = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = shader_stages.len;
        pipeline_info.pStages = &shader_stages;
        pipeline_info.pVertexInputState = &vertex_input;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pColorBlendState = &color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = self.pipeline_layout;
        pipeline_info.renderPass = self.render_pass;
        pipeline_info.subpass = 0;

        if (c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.graphics_pipeline) != c.VK_SUCCESS) {
            return error.VkGraphicsPipelineCreateFailed;
        }
    }

    fn createShaderModule(self: *Engine, code: []const u8) !c.VkShaderModule {
        const u32_count = (code.len + 3) / 4;
        const aligned_buf = try self.allocator.alloc(u32, u32_count);
        defer self.allocator.free(aligned_buf);
        @memcpy(std.mem.sliceAsBytes(aligned_buf)[0..code.len], code);

        var create_info: c.VkShaderModuleCreateInfo = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        create_info.codeSize = code.len;
        create_info.pCode = aligned_buf.ptr;

        var module: c.VkShaderModule = null;
        if (c.vkCreateShaderModule(self.device, &create_info, null, &module) != c.VK_SUCCESS) {
            return error.VkShaderModuleCreateFailed;
        }
        return module;
    }

    fn createDescriptorPool(self: *Engine) !void {
        var pool_size: c.VkDescriptorPoolSize = std.mem.zeroes(c.VkDescriptorPoolSize);
        pool_size.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        pool_size.descriptorCount = 1000;

        var pool_info: c.VkDescriptorPoolCreateInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.poolSizeCount = 1;
        pool_info.pPoolSizes = &pool_size;
        pool_info.maxSets = 1000;

        if (c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool) != c.VK_SUCCESS) {
            return error.VkDescriptorPoolCreateFailed;
        }
    }

    fn createFramebuffers(self: *Engine) !void {
        self.swapchain_framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len);
        for (self.swapchain_image_views, 0..) |view, i| {
            var fb_info: c.VkFramebufferCreateInfo = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &view;
            fb_info.width = self.swapchain_extent.width;
            fb_info.height = self.swapchain_extent.height;
            fb_info.layers = 1;

            if (c.vkCreateFramebuffer(self.device, &fb_info, null, &self.swapchain_framebuffers[i]) != c.VK_SUCCESS) {
                return error.VkFramebufferCreateFailed;
            }
        }
    }

    fn createCommandPool(self: *Engine) !void {
        var pool_info: c.VkCommandPoolCreateInfo = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = self.graphics_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

        if (c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool) != c.VK_SUCCESS) {
            return error.VkCommandPoolCreateFailed;
        }

        self.command_buffers = try self.allocator.alloc(c.VkCommandBuffer, self.swapchain_images.len);
        var alloc_info: c.VkCommandBufferAllocateInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = @intCast(self.command_buffers.len);

        if (c.vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr) != c.VK_SUCCESS) {
            return error.VkCommandBufferAllocFailed;
        }
    }

    fn createSyncObjects(self: *Engine) !void {
        var sem_info: c.VkSemaphoreCreateInfo = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        var fence_info: c.VkFenceCreateInfo = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (c.vkCreateSemaphore(self.device, &sem_info, null, &self.image_available_semaphores[i]) != c.VK_SUCCESS or
                c.vkCreateSemaphore(self.device, &sem_info, null, &self.render_finished_semaphores[i]) != c.VK_SUCCESS or
                c.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[i]) != c.VK_SUCCESS)
            {
                return error.VkSyncObjectCreateFailed;
            }
        }
    }

    fn findMemoryType(self: *Engine, type_filter: u32, properties: c.VkMemoryPropertyFlags) u32 {
        var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_props);

        for (0..mem_props.memoryTypeCount) |i| {
            const idx: u32 = @intCast(i);
            if ((type_filter & (@as(u32, 1) << @truncate(idx))) != 0 and
                (mem_props.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return idx;
            }
        }
        return 0;
    }

    fn createBuffer(
        self: *Engine,
        size: c.VkDeviceSize,
        usage: c.VkBufferUsageFlags,
        properties: c.VkMemoryPropertyFlags,
        buffer: *c.VkBuffer,
        memory: *c.VkDeviceMemory,
    ) !void {
        var buf_info: c.VkBufferCreateInfo = std.mem.zeroes(c.VkBufferCreateInfo);
        buf_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buf_info.size = size;
        buf_info.usage = usage;
        buf_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        if (c.vkCreateBuffer(self.device, &buf_info, null, buffer) != c.VK_SUCCESS) {
            return error.VkBufferCreateFailed;
        }

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buffer.*, &mem_reqs);

        var alloc_info: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = self.findMemoryType(mem_reqs.memoryTypeBits, properties);

        if (c.vkAllocateMemory(self.device, &alloc_info, null, memory) != c.VK_SUCCESS) {
            return error.VkMemoryAllocFailed;
        }

        _ = c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0);
    }

    fn createVertexBuffer(self: *Engine) !void {
        const size: c.VkDeviceSize = @sizeOf(Vertex) * types.quad_vertices.len;
        try self.createBuffer(
            size,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );

        var data: ?*anyopaque = null;
        _ = c.vkMapMemory(self.device, self.vertex_buffer_memory, 0, size, 0, &data);
        @memcpy(@as([*]Vertex, @ptrCast(@alignCast(data.?)))[0..types.quad_vertices.len], &types.quad_vertices);
        c.vkUnmapMemory(self.device, self.vertex_buffer_memory);
    }

    fn beginSingleTimeCommands(self: *Engine) c.VkCommandBuffer {
        var alloc_info: c.VkCommandBufferAllocateInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandPool = self.command_pool;
        alloc_info.commandBufferCount = 1;

        var cmd: c.VkCommandBuffer = null;
        _ = c.vkAllocateCommandBuffers(self.device, &alloc_info, &cmd);

        var begin_info: c.VkCommandBufferBeginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        _ = c.vkBeginCommandBuffer(cmd, &begin_info);

        return cmd;
    }

    fn endSingleTimeCommands(self: *Engine, cmd: c.VkCommandBuffer) void {
        _ = c.vkEndCommandBuffer(cmd);

        var submit_info: c.VkSubmitInfo = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cmd;

        _ = c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, null);
        _ = c.vkQueueWaitIdle(self.graphics_queue);

        c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &cmd);
    }

    fn createRenderTarget(self: *Engine) !void {
        const w: u32 = @intCast(self.viewport.virtual_width);
        const h: u32 = @intCast(self.viewport.virtual_height);

        var img_info: c.VkImageCreateInfo = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent.width = w;
        img_info.extent.height = h;
        img_info.extent.depth = 1;
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = self.swapchain_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        _ = c.vkCreateImage(self.device, &img_info, null, &self.offscreen_tex.image);

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.offscreen_tex.image, &mem_reqs);

        var alloc_info: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = self.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        _ = c.vkAllocateMemory(self.device, &alloc_info, null, &self.offscreen_tex.memory);
        _ = c.vkBindImageMemory(self.device, self.offscreen_tex.image, self.offscreen_tex.memory, 0);

        self.offscreen_tex.width = w;
        self.offscreen_tex.height = h;

        var view_info: c.VkImageViewCreateInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.offscreen_tex.image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = self.swapchain_format;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.levelCount = 1;
        view_info.subresourceRange.layerCount = 1;
        _ = c.vkCreateImageView(self.device, &view_info, null, &self.offscreen_tex.view);

        var sampler_info: c.VkSamplerCreateInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_NEAREST;
        sampler_info.minFilter = c.VK_FILTER_NEAREST;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        _ = c.vkCreateSampler(self.device, &sampler_info, null, &self.offscreen_tex.sampler);

        var ds_alloc: c.VkDescriptorSetAllocateInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_alloc.descriptorPool = self.descriptor_pool;
        ds_alloc.descriptorSetCount = 1;
        ds_alloc.pSetLayouts = &self.descriptor_set_layout;
        _ = c.vkAllocateDescriptorSets(self.device, &ds_alloc, &self.offscreen_tex.descriptor);

        var img_desc: c.VkDescriptorImageInfo = std.mem.zeroes(c.VkDescriptorImageInfo);
        img_desc.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        img_desc.imageView = self.offscreen_tex.view;
        img_desc.sampler = self.offscreen_tex.sampler;

        var write_desc: c.VkWriteDescriptorSet = std.mem.zeroes(c.VkWriteDescriptorSet);
        write_desc.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write_desc.dstSet = self.offscreen_tex.descriptor;
        write_desc.dstBinding = 0;
        write_desc.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write_desc.descriptorCount = 1;
        write_desc.pImageInfo = &img_desc;
        c.vkUpdateDescriptorSets(self.device, 1, &write_desc, 0, null);

        var color_attachment: c.VkAttachmentDescription = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = self.swapchain_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var color_ref: c.VkAttachmentReference = std.mem.zeroes(c.VkAttachmentReference);
        color_ref.attachment = 0;
        color_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var subpass: c.VkSubpassDescription = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var pass_info: c.VkRenderPassCreateInfo = std.mem.zeroes(c.VkRenderPassCreateInfo);
        pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        pass_info.attachmentCount = 1;
        pass_info.pAttachments = &color_attachment;
        pass_info.subpassCount = 1;
        pass_info.pSubpasses = &subpass;

        _ = c.vkCreateRenderPass(self.device, &pass_info, null, &self.offscreen_pass);

        var fb_info: c.VkFramebufferCreateInfo = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = self.offscreen_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &self.offscreen_tex.view;
        fb_info.width = w;
        fb_info.height = h;
        fb_info.layers = 1;
        _ = c.vkCreateFramebuffer(self.device, &fb_info, null, &self.offscreen_framebuffer);
    }

    pub fn recreateSwapChain(self: *Engine) void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &width, &height);
        while (width == 0 or height == 0) {
            c.glfwGetFramebufferSize(self.window, &width, &height);
            c.glfwWaitEvents();
        }

        _ = c.vkDeviceWaitIdle(self.device);

        for (self.swapchain_framebuffers) |fb| c.vkDestroyFramebuffer(self.device, fb, null);
        self.allocator.free(self.swapchain_framebuffers);

        for (self.swapchain_image_views) |iv| c.vkDestroyImageView(self.device, iv, null);
        self.allocator.free(self.swapchain_image_views);
        self.allocator.free(self.swapchain_images);

        c.vkDestroySwapchainKHR(self.device, self.swapchain, null);

        self.createSwapChain() catch return;
        self.createFramebuffers() catch return;
    }

    pub fn createTexture(self: *Engine, pixels: []const u8, width: u32, height: u32) Texture {
        const image_size: c.VkDeviceSize = width * height * 4;

        var staging_buffer: c.VkBuffer = null;
        var staging_memory: c.VkDeviceMemory = null;
        self.createBuffer(
            image_size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) catch unreachable;

        var data: ?*anyopaque = null;
        _ = c.vkMapMemory(self.device, staging_memory, 0, image_size, 0, &data);
        @memcpy(@as([*]u8, @ptrCast(data.?))[0..pixels.len], pixels);
        c.vkUnmapMemory(self.device, staging_memory);

        var tex = Texture{
            .width = width,
            .height = height,
        };

        var img_info: c.VkImageCreateInfo = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent.width = width;
        img_info.extent.height = height;
        img_info.extent.depth = 1;
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = c.VK_FORMAT_R8G8B8A8_SRGB;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        _ = c.vkCreateImage(self.device, &img_info, null, &tex.image);

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, tex.image, &mem_reqs);

        var alloc_info: c.VkMemoryAllocateInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = self.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        _ = c.vkAllocateMemory(self.device, &alloc_info, null, &tex.memory);
        _ = c.vkBindImageMemory(self.device, tex.image, tex.memory, 0);

        const cmd = self.beginSingleTimeCommands();
        self.transitionImageLayout(cmd, tex.image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        self.copyBufferToImage(cmd, staging_buffer, tex.image, width, height);
        self.transitionImageLayout(cmd, tex.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        self.endSingleTimeCommands(cmd);

        c.vkDestroyBuffer(self.device, staging_buffer, null);
        c.vkFreeMemory(self.device, staging_memory, null);

        var view_info: c.VkImageViewCreateInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = tex.image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_SRGB;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.levelCount = 1;
        view_info.subresourceRange.layerCount = 1;
        _ = c.vkCreateImageView(self.device, &view_info, null, &tex.view);

        var sampler_info: c.VkSamplerCreateInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_NEAREST;
        sampler_info.minFilter = c.VK_FILTER_NEAREST;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        _ = c.vkCreateSampler(self.device, &sampler_info, null, &tex.sampler);

        var ds_alloc: c.VkDescriptorSetAllocateInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_alloc.descriptorPool = self.descriptor_pool;
        ds_alloc.descriptorSetCount = 1;
        ds_alloc.pSetLayouts = &self.descriptor_set_layout;
        _ = c.vkAllocateDescriptorSets(self.device, &ds_alloc, &tex.descriptor);

        var img_desc: c.VkDescriptorImageInfo = std.mem.zeroes(c.VkDescriptorImageInfo);
        img_desc.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        img_desc.imageView = tex.view;
        img_desc.sampler = tex.sampler;

        var write_desc: c.VkWriteDescriptorSet = std.mem.zeroes(c.VkWriteDescriptorSet);
        write_desc.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write_desc.dstSet = tex.descriptor;
        write_desc.dstBinding = 0;
        write_desc.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write_desc.descriptorCount = 1;
        write_desc.pImageInfo = &img_desc;
        c.vkUpdateDescriptorSets(self.device, 1, &write_desc, 0, null);

        return tex;
    }

    pub fn updateTexture(self: *Engine, tex: Texture, pixels: []const u8, width: u32, height: u32) void {
        const image_size: c.VkDeviceSize = width * height * 4;

        var staging_buffer: c.VkBuffer = null;
        var staging_memory: c.VkDeviceMemory = null;
        self.createBuffer(
            image_size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) catch return;

        var data: ?*anyopaque = null;
        _ = c.vkMapMemory(self.device, staging_memory, 0, image_size, 0, &data);
        @memcpy(@as([*]u8, @ptrCast(data.?))[0..pixels.len], pixels);
        c.vkUnmapMemory(self.device, staging_memory);

        const cmd = self.beginSingleTimeCommands();
        self.transitionImageLayout(cmd, tex.image, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        self.copyBufferToImage(cmd, staging_buffer, tex.image, width, height);
        self.transitionImageLayout(cmd, tex.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        self.endSingleTimeCommands(cmd);

        c.vkDestroyBuffer(self.device, staging_buffer, null);
        c.vkFreeMemory(self.device, staging_memory, null);
    }

    fn transitionImageLayout(_: *Engine, cmd: c.VkCommandBuffer, image: c.VkImage, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) void {
        var barrier: c.VkImageMemoryBarrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = old_layout;
        barrier.newLayout = new_layout;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;

        var src_stage: c.VkPipelineStageFlags = 0;
        var dst_stage: c.VkPipelineStageFlags = 0;

        if (old_layout == c.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (old_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            src_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else {
            src_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        }

        c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    }

    fn copyBufferToImage(_: *Engine, cmd: c.VkCommandBuffer, buffer: c.VkBuffer, image: c.VkImage, width: u32, height: u32) void {
        var region: c.VkBufferImageCopy = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent.width = width;
        region.imageExtent.height = height;
        region.imageExtent.depth = 1;

        c.vkCmdCopyBufferToImage(cmd, buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    }

    pub fn drawFrame(self: *Engine) void {
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &fb_w, &fb_h);
        if (fb_w == 0 or fb_h == 0) return;

        if (self.framebuffer_resized) {
            self.framebuffer_resized = false;
            self.recreateSwapChain();
        }

        self.viewport.update(fb_w, fb_h);

        _ = c.vkWaitForFences(self.device, 1, &self.in_flight_fences[self.current_frame], c.VK_TRUE, 100_000_000);

        var image_index: u32 = 0;
        var result = c.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            100_000_000,
            self.image_available_semaphores[self.current_frame],
            null,
            &image_index,
        );

        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR) {
            self.recreateSwapChain();
            result = c.vkAcquireNextImageKHR(
                self.device,
                self.swapchain,
                100_000_000,
                self.image_available_semaphores[self.current_frame],
                null,
                &image_index,
            );
            if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) return;
        } else if (result != c.VK_SUCCESS) {
            return;
        }

        _ = c.vkResetFences(self.device, 1, &self.in_flight_fences[self.current_frame]);
        _ = c.vkResetCommandBuffer(self.command_buffers[image_index], 0);

        const cmd = self.command_buffers[image_index];
        var begin_info: c.VkCommandBufferBeginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        _ = c.vkBeginCommandBuffer(cmd, &begin_info);

        var offscreen_clear: c.VkClearValue = std.mem.zeroes(c.VkClearValue);
        offscreen_clear.color.float32[3] = 1.0;

        var offscreen_pass_info: c.VkRenderPassBeginInfo = std.mem.zeroes(c.VkRenderPassBeginInfo);
        offscreen_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        offscreen_pass_info.renderPass = self.offscreen_pass;
        offscreen_pass_info.framebuffer = self.offscreen_framebuffer;
        offscreen_pass_info.renderArea.extent.width = @intCast(self.viewport.virtual_width);
        offscreen_pass_info.renderArea.extent.height = @intCast(self.viewport.virtual_height);
        offscreen_pass_info.clearValueCount = 1;
        offscreen_pass_info.pClearValues = &offscreen_clear;

        c.vkCmdBeginRenderPass(cmd, &offscreen_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

        var vp: c.VkViewport = undefined;
        vp.x = 0;
        vp.y = 0;
        vp.width = @floatFromInt(self.viewport.virtual_width);
        vp.height = @floatFromInt(self.viewport.virtual_height);
        vp.minDepth = 0.0;
        vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &vp);

        var sc: c.VkRect2D = undefined;
        sc.offset.x = 0;
        sc.offset.y = 0;
        sc.extent.width = @intCast(self.viewport.virtual_width);
        sc.extent.height = @intCast(self.viewport.virtual_height);
        c.vkCmdSetScissor(cmd, 0, 1, &sc);

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vertex_buffer, &offset);

        for (renderer2d.draw_list.items) |sprite| {
            if (sprite.visible) self.drawSprite(cmd, sprite);
        }

        for (renderer2d.frame_list.items) |sprite| {
            if (sprite.visible) self.drawSprite(cmd, sprite);
        }

        c.vkCmdEndRenderPass(cmd);

        self.transitionImageLayout(
            cmd,
            self.offscreen_tex.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        );

        var swapchain_clear: c.VkClearValue = std.mem.zeroes(c.VkClearValue);
        swapchain_clear.color.float32[3] = 1.0;

        var swapchain_pass_info: c.VkRenderPassBeginInfo = std.mem.zeroes(c.VkRenderPassBeginInfo);
        swapchain_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        swapchain_pass_info.renderPass = self.render_pass;
        swapchain_pass_info.framebuffer = self.swapchain_framebuffers[image_index];
        swapchain_pass_info.renderArea.extent = self.swapchain_extent;
        swapchain_pass_info.clearValueCount = 1;
        swapchain_pass_info.pClearValues = &swapchain_clear;

        c.vkCmdBeginRenderPass(cmd, &swapchain_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

        var up_vp: c.VkViewport = undefined;
        up_vp.x = @floatFromInt(self.viewport.offset_x);
        up_vp.y = @floatFromInt(self.viewport.offset_y);
        up_vp.width = @floatFromInt(self.viewport.view_width);
        up_vp.height = @floatFromInt(self.viewport.view_height);
        up_vp.minDepth = 0.0;
        up_vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &up_vp);

        var up_sc: c.VkRect2D = undefined;
        up_sc.offset.x = self.viewport.offset_x;
        up_sc.offset.y = self.viewport.offset_y;
        up_sc.extent.width = @intCast(self.viewport.view_width);
        up_sc.extent.height = @intCast(self.viewport.view_height);
        c.vkCmdSetScissor(cmd, 0, 1, &up_sc);

        c.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vertex_buffer, &offset);

        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &self.offscreen_tex.descriptor,
            0,
            null,
        );

        const upscale_push = Push{
            .color = .{ 1, 1, 1, 1 },
            .screen = .{ @floatFromInt(self.viewport.virtual_width), @floatFromInt(self.viewport.virtual_height) },
            .pos = .{ 0, 0 },
            .size = .{ @floatFromInt(self.viewport.virtual_width), @floatFromInt(self.viewport.virtual_height) },
            .uv0 = .{ 0, 0 },
            .uv1 = .{ 1, 1 },
        };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(Push),
            &upscale_push,
        );
        c.vkCmdDraw(cmd, 6, 1, 0, 0);

        c.vkCmdEndRenderPass(cmd);

        _ = c.vkEndCommandBuffer(cmd);

        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        var submit_info: c.VkSubmitInfo = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.waitSemaphoreCount = 1;
        submit_info.pWaitSemaphores = &self.image_available_semaphores[self.current_frame];
        submit_info.pWaitDstStageMask = &wait_stages;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &self.command_buffers[image_index];
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &self.render_finished_semaphores[self.current_frame];

        if (c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight_fences[self.current_frame]) != c.VK_SUCCESS) {
            std.debug.print("vkQueueSubmit failed\n", .{});
        }

        var present_info: c.VkPresentInfoKHR = std.mem.zeroes(c.VkPresentInfoKHR);
        present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &self.render_finished_semaphores[self.current_frame];
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain;
        present_info.pImageIndices = &image_index;

        const present_result = c.vkQueuePresentKHR(self.present_queue, &present_info);
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = true;
        }

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
        renderer2d.frame_list.clearRetainingCapacity();
    }

    fn drawSprite(self: *Engine, cmd: c.VkCommandBuffer, s: Sprite) void {
        if (s.texture_id >= texture_mod.textures.items.len) return;
        const tex = texture_mod.textures.items[s.texture_id];

        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &tex.descriptor,
            0,
            null,
        );

        const push = Push{
            .color = s.color,
            .screen = .{ @floatFromInt(self.viewport.virtual_width), @floatFromInt(self.viewport.virtual_height) },
            .pos = s.pos,
            .size = s.size,
            .rot = s.rot,
            .scale = s.scale,
            .uv0 = s.uv0,
            .uv1 = s.uv1,
        };

        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(Push),
            &push,
        );

        c.vkCmdDraw(cmd, 6, 1, 0, 0);
    }
};

fn createTextureCallback(ctx: *anyopaque, pixels: []const u8, width: u32, height: u32) Texture {
    const engine: *Engine = @alignCast(@ptrCast(ctx));
    return engine.createTexture(pixels, width, height);
}

fn updateTextureCallback(ctx: *anyopaque, tex: Texture, pixels: []const u8, width: u32, height: u32) void {
    const engine: *Engine = @alignCast(@ptrCast(ctx));
    engine.updateTexture(tex, pixels, width, height);
}
