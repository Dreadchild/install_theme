$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

require 'rubigen'
require 'rubigen/scripts/generate'
require 'hpricot'
require 'ostruct'

class InstallTheme
  VERSION = "0.8.1"
  
  attr_reader :template_root, :rails_root, :index_path, :template_type
  attr_reader :layout_name, :action
  attr_reader :stylesheet_dir, :javascript_dir, :image_dir
  attr_reader :defaults_file
  attr_reader :content_path, :partials
  attr_reader :stdout
  attr_reader :original_named_yields, :original_body_content
  
  def initialize(options = {})
    @template_root  = File.expand_path(options[:template_root] || File.dirname('.'))
    @rails_root     = File.expand_path(options[:rails_root] || File.dirname('.'))
    @template_type  = (options[:template_type] || detect_template).to_s
    @defaults_file  = options[:defaults_file] || "install_theme.yml"
    @stylesheet_dir = options[:stylesheet_dir] || detect_stylesheet_dir
    @javascript_dir = options[:javascript_dir] || detect_javascript_dir
    @image_dir      = options[:image_dir] || detect_image_dir
    @layout_name    = options[:layout] || "application"
    @layout_name.gsub!(/\..*/, '') # allow application.html.erb to be passed in, but clean it up to 'application'
    @action         = options[:action]

    @stdout         = options[:stdout] || $stdout

    load_template_defaults unless options[:ignore_defaults]
    @index_path     = options[:index_path] || @index_path || "index.html"
    @content_path   = options[:content_path] || @content_path
    @partials       ||= {}
    @partials.merge!(options[:partials]) if options[:partials]
    
    create_install_theme_yml
    setup_template_temp_path
  end
  
  def apply_to_target(options = {})
    require_haml if haml?
    @stdout = options[:stdout] || @stdout || $stdout
    @original_named_yields = {}
    convert_file_to_layout(index_path, "app/views/layouts/#{layout_name}.html.erb")
    convert_to_haml("app/views/layouts/#{layout_name}.html.erb") if haml?
    prepare_action
    prepare_sample_controller_and_view
    prepare_layout_partials
    prepare_assets
    prepare_helpers
    run_generator(options)
    show_readme
  end
  
  # This generator's templates folder is temporary
  # and is accessed via source_root within the generator.
  def template_temp_path
    @template_temp_path ||= begin
      template_path = File.join(tmp_dir, "install_theme", "templates")
    end
  end
  
  def setup_template_temp_path
    FileUtils.rm_rf(template_temp_path)
    FileUtils.mkdir_p(template_temp_path)
    %w[app/views/layouts public/images public/javascripts public/stylesheets].each do |app_path|
      FileUtils.mkdir_p(File.join(template_temp_path, app_path))
    end
  end
  
  def haml?
    template_type == 'haml'
  end
  
  def erb?
    template_type == 'erb'
  end
  
  def valid?
    template_root && File.exist?(template_root) &&
    rails_root && File.exist?(rails_root) &&
    content_path
  end
  
  protected
  
  def load_template_defaults
    return unless File.exist?(File.join(template_root, defaults_file))
    require "yaml"
    defaults = YAML.load_file(File.join(template_root, defaults_file))
    @content_path = defaults["content_path"]
    @partials     = defaults["partials"]
    @index_path   = defaults["index_path"]
  end
  
  def convert_file_to_layout(html_path, layout_path)
    File.open(File.join(template_temp_path, layout_path), "w") do |f|
      contents = File.read(File.join(template_root, html_path)).gsub(/\r/, '')
      template_images.each do |file|
        image = File.basename(file)
        contents.gsub!(%r{(["'])/?[\w_\-\/]*#{image}}, '\1/images/' + image)
      end
      template_stylesheets.each do |file|
        stylesheet = File.basename(file)
        contents.gsub!(%r{(["'])/?[\w_\-\/]*#{stylesheet}}, '\1/stylesheets/' + stylesheet)
      end
      template_javascripts.each do |file|
        javascript = File.basename(file)
        contents.gsub!(%r{(["'])/?[\w_\-\/]*#{javascript}}, '\1/javascripts/' + javascript)
      end

      contents.gsub!(%r{(["'])/?#{image_dir}}, '\1/images') unless image_dir.blank?
      contents.gsub!(%r{(["'])/?#{stylesheet_dir}}, '\1/stylesheets') unless stylesheet_dir.blank?
      contents.gsub!(%r{(["'])/?#{javascript_dir}}, '\1/javascripts') unless javascript_dir.blank?

      contents.sub!(%r{\s*</head>}, <<-EOS.gsub(/^      /, '').gsub(/\n$/, ''))
      
        <%= javascript_include_tag :all %>
        <%= yield(:head) %>
      </head>
      EOS

      doc = Hpricot(contents)
      @original_body_content = replace_by_path(doc, content_path, "<%= yield %>")
      partials.to_a.each do |name, css_path|
        original_named_yields[name] = 
          replace_by_path(doc, css_path, "<%= yield(:#{name}) || render_or_default('#{name}') %>")
      end
      contents = doc.to_html
      f << contents
    end
  end
  
  # see replace_by_path_spec.rb for examples
  def replace_by_path(doc, path, replacement)
    result = ""
    return "" unless path && path.strip.match(/^(.*?)(|\s*:text|\s*\/?text\(\))$/)
    outer_path, is_text = $1, !$2.blank?
    if node = doc.search(outer_path).first
      if is_text
        result = node.inner_html
        node.inner_html = replacement
      else
        result = node.to_html
        node.parent.replace_child(node, Hpricot::Text.new(replacement))
      end
    end
    result
  end
  
  def convert_to_haml(path)
    from_path = File.join(template_temp_path, path)
    haml_path = from_path.gsub(/erb$/, "haml")
    html2haml(from_path, haml_path)
    # only remove .erb if haml conversion successful
    if File.size?(haml_path)
      FileUtils.rm_rf(from_path)
    else
      FileUtils.rm_rf(haml_path)
    end
  end

  def convert_to_sass(from_path)
    sass_path = from_path.gsub(/css$/, "sass").gsub(%r{public/stylesheets/}, 'public/stylesheets/sass/')
    FileUtils.mkdir_p(File.dirname(sass_path))
    css2sass(from_path, sass_path)
    # only remove .erb if haml conversion successful
    if File.size?(sass_path)
      FileUtils.rm_rf(from_path)
    else
      FileUtils.rm_rf(sass_path)
    end
  end
  
  # The extracted chunks of HTML are retained in
  # app/views/original_template/index.html.erb (or haml)
  # wrapped in content_for blocks.
  #
  # Users can review this file for ideas of what HTML
  # works best in each section.
  def prepare_sample_controller_and_view
    FileUtils.chdir(template_temp_path) do
      FileUtils.mkdir_p("app/controllers")
      File.open("app/controllers/original_template_controller.rb", "w") { |f| f << <<-EOS.gsub(/^      /, '') }
      class OriginalTemplateController < ApplicationController
      end
      EOS

      FileUtils.mkdir_p("app/views/original_template")
      File.open("app/views/original_template/index.html.erb", "w") do |f|
        f << "<p>You are using named yields. Here are examples how to use them:</p>\n"
        f << show_content_for(:head, '<script></script>')
        original_named_yields.to_a.each do |key, original_contents|
          f << show_content_for(key, original_contents)
          f << "\n"
        end
        f << "\n\n"
        if original_body_content
          f << "<!-- original body content -->"
          f << original_body_content
        end
      end
    end
    convert_to_haml('app/views/original_template/index.html.erb') if haml?
  end
  
  def prepare_action
    return unless action
    action_path = "app/views/#{action}.html.erb"
    target_path = File.join(template_temp_path, action_path)
    FileUtils.mkdir_p(File.dirname(target_path))
    File.open(target_path, "w") do |f|
      f << original_body_content
    end
    convert_to_haml(action_path) if haml?
  end
  
  def prepare_layout_partials
    original_named_yields.to_a.each do |key, original_contents|
      partial_file = "app/views/layouts/_#{key}.html.erb"
      File.open(File.join(template_temp_path, partial_file), "w") do |f|
        f << original_contents.strip
      end
      convert_to_haml(partial_file) if haml?
    end
  end

  def prepare_assets
    template_stylesheets.each do |file|
      target_path = File.join(template_temp_path, 'public/stylesheets', File.basename(file))
      File.open(target_path, "w") do |f|
        f << clean_stylesheet(File.read(file))
      end
      convert_to_sass(target_path) if haml?
    end
    template_javascripts.each do |file|
      FileUtils.cp_r(file, File.join(template_temp_path, 'public/javascripts'))
    end
    template_images.each do |file|
      FileUtils.cp_r(file, File.join(template_temp_path, 'public/images'))
    end
  end
  
  def prepare_helpers
    root = File.join(File.dirname(__FILE__), "install_theme", "templates")
    Dir[File.join(root, "**/*")].each do |f|
      templates_file = f.gsub(root, "").gsub(%r{^/}, '')
      FileUtils.cp_r(f, File.join(template_temp_path, templates_file))
    end
  end
  
  def run_generator(options)
    # now use rubigen to install the files into the rails app
    # so users can get conflict resolution options from command line
    RubiGen::Base.reset_sources
    RubiGen::Base.prepend_sources(RubiGen::PathSource.new(:internal, File.dirname(__FILE__)))
    generator_options = options[:generator] || {}
    generator_options.merge!(:stdout => @stdout, :no_exit => true,
      :source => template_temp_path, :destination => rails_root)
    RubiGen::Scripts::Generate.new.run(["install_theme"], generator_options)
  end
  
  # converts +from+ HTML into +to+ HAML
  # +from+ is a file name
  # +to+ is a file name
  def html2haml(from, to)
    Open3.popen3("html2haml #{from} #{to}") { |stdin, stdout, stderr| stdout.read }
    # TODO - the following is failing for some reason
    # converter = Haml::Exec::HTML2Haml.new([])
    # from = File.read(from) if File.exist?(from)
    # to   = File.open(to, "w") unless to.respond_to?(:write)
    # converter.instance_variable_set("@options", { :input => from, :output => to })
    # converter.instance_variable_set("@module_opts", { :rhtml => true })
    # begin
    #   converter.send(:process_result)
    # rescue Exception => e
    #   stdout.puts "Failed to convert #{File.basename(from)} to haml"
    # end
    # to.close if to.respond_to?(:close)
  end

  def css2sass(from, to)
    converter = Haml::Exec::CSS2Sass.new([])
    from = File.read(from) if File.exist?(from)
    to   = File.open(to, "w") unless to.respond_to?(:write)
    converter.instance_variable_set("@options", { :input => from, :output => to })
    converter.instance_variable_set("@module_opts", { :rhtml => true })
    begin
      converter.send(:process_result)
    rescue Exception => e
    end
    to.close if to.respond_to?(:close)
  end

  def in_template_root(&block)
    FileUtils.chdir(template_root, &block)
  end
  
  def in_rails_root(&block)
    FileUtils.chdir(rails_root, &block)
  end
  
  def create_install_theme_yml
    config = { "content_path" => content_path, "partials" => partials, "index_path" => index_path }
    install_theme_yml = File.join(template_root, 'install_theme.yml')
    File.open(install_theme_yml, 'w') {|f| f << config.to_yaml}
  end

  def detect_template
    if detect_template_haml
      'haml'
    else
      'erb'
    end
  end
  
  def detect_template_haml
    in_rails_root do
      return true if File.exist?('vendor/plugins/haml')
      return true if File.exist?('config/environment.rb') && File.read('config/environment.rb') =~ /haml/
    end
  end
  
  def detect_stylesheet_dir
    if path = Dir[File.join(template_root, '**/*.css')].first
      File.dirname(path).gsub(template_root, '').gsub(%r{^/}, '')
    else
      'stylesheets'
    end
  end
  
  def detect_javascript_dir
    if path = Dir[File.join(template_root, '**/*.js')].first
      File.dirname(path).gsub(template_root, '').gsub(%r{^/}, '')
    else
      'javascripts'
    end
  end
  
  def detect_image_dir
    if path = Dir[File.join(template_root, '**/*.{jpg,png,gif}')].first
      File.dirname(path).gsub(template_root, '').gsub(%r{^/}, '')
    else
      'images'
    end
  end
  
  def template_stylesheets
    Dir[File.join(template_root, stylesheet_dir, '**/*.css')]
  end
  
  def template_javascripts
    Dir[File.join(template_root, javascript_dir, '**/*.js')]
  end

  def template_images
    Dir[File.join(template_root, image_dir, '**/*.{jpg,png,gif}')]
  end
  
  def clean_stylesheet(contents)
    contents.gsub(%r{url\((["']?)[\./]*(#{image_dir}|#{stylesheet_dir}|)\/?(.*?)(["']?)\)}) do |match|
      quote, path, file_name = $1, $2, $3
      target_path = "stylesheets" if file_name =~ /css$/
      target_path ||= (!stylesheet_dir.blank? && path == stylesheet_dir) ? "stylesheets" : "images"
      "url(#{quote}/#{target_path}/#{file_name}#{quote})"
    end
  end
  
  def show_readme
    stdout.puts <<-README
    
    Your theme has been installed into your app.
    
    README
  end
  
  def show_content_for(key, contents)
    <<-EOS.gsub(/^    /, '')
    <% content_for :#{key} do -%>
      #{contents}
    <% end -%>
    EOS
  end
  
  def tmp_dir
    ENV['TMPDIR'] || '/tmp'
  end
  
  def require_haml
    require 'haml'
    require 'haml/html'
    require 'sass'
    require 'sass/css'
    require 'haml/exec'
    require 'open3'
  end
end

require "install_theme/parsers"
