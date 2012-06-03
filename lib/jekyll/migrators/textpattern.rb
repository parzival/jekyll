require 'rubygems'
require 'sequel'
require 'fileutils'
require 'yaml'

# To migrate from Textpattern with images, this command can be used: 
# ruby -rubygems -e 'require "jekyll/migrators/textpattern"; Jekyll::TextPattern.process("database_name", "username", "password", "hostname", "textpattern_base_directory")'

# NOTE: This converter requires Sequel and the MySQL gems.
# The MySQL gem can be difficult to install on OS X. Once you have MySQL
# installed, running the following commands should work:
# $ sudo gem install sequel
# $ sudo gem install mysql -- --with-mysql-config=/usr/local/mysql/bin/mysql_config

module Jekyll
  module TextPattern
    # Reads a MySQL database via Sequel and creates a post file for each post.
    
    # The only posts selected are those with a status of 4 or 5, which means
    # "live" and "sticky" respectively.
    # Other statuses are 1 => draft, 2 => hidden and 3 => pending.
    QUERY = "SELECT Title, \
                    url_title, \
                    Posted, \
                    Body, \
                    Keywords \
             FROM textpattern \
             WHERE Status = '4' OR \
                   Status = '5'"
    
    # Name of directories to place the results in
    POST_DEST = "_posts"
    IMG_DEST  = "images/import"
    
    # HTML img tags will be built from this prefix plus the destination directory 
    IMG_BASE_URL = '/'
    
    # Image processing is done on image, thumbnail, and article-image tags only.
    # Information on images is taken from the MySQL database, but the images themselves will be in another directory.  This base directory for Textpattern must be specified. The relative location of the image directory is taken from the txp_prefs table.
    
    IMG_DIR_QUERY = "SELECT val \
                     FROM txp_prefs \
                     WHERE name = 'img_dir'"
                     
    IMG_QUERY = "SELECT id, name, ext, alt, thumbnail \
                 FROM txp_image" 
                 
    # Finds prefix name from config.php file
    TXP_CONFIG_FILE = 'textpattern/config.php'
    TXP_PREFIX_CONFIG = /\$txpcfg\['table_prefix'\] = '(.*?)'/
    
    # Only works for non-nested tags (and those without html or a '/>' in them)             
    TXP_TAG = /<txp:(.*?)\/>/
    
    # All tag attributes except for these are passed on to the HTML img tag
    IGNORED_TXP_ATTRIBS = ["thumbnail","name","id","escape","wraptag","html_id"]
        
    def self.process(dbname, user, pass, host = 'localhost', txp_dir = nil)
      db = Sequel.mysql(dbname, :user => user, :password => pass, :host => host, :encoding => 'utf8')
      
      # Textpattern has an optional prefix for database table names. It will be specified in the config file, so try to get it from there.
      txp_prefix = ''
      
      if txp_dir
        txp_config = File.join(txp_dir,TXP_CONFIG_FILE)
        if File.exist?(txp_config)
          File.open(txp_config).each_line do |line|
            if line =~ TXP_PREFIX_CONFIG
              txp_prefix = $1
            end
          end
        else
          $stdout.puts "Missing Textpattern config file: #{txp_config}."
        end
      end
      
      
      if txp_prefix != ''
        {"textpattern"=>QUERY,"txp_prefs"=>IMG_DIR_QUERY,"txp_image"=>IMG_QUERY}.each do |table,qry|
          qry.gsub!(table,txp_prefix+table)
        end
      end  

      FileUtils.mkdir_p POST_DEST    
      
      if txp_dir
        image_dir = File.join(txp_dir,db[IMG_DIR_QUERY][:val][:val]) 
      end 
      
      if File.exist?(image_dir)
        FileUtils.mkdir_p IMG_DEST
        process_images = true
      else
        $stderr.puts "Could not locate Textpattern image directory:#{img_dir}" if txp_dir
        $stdout.puts "Skipping image processing - no image directory"
      end
      
      db[QUERY].each do |post|
        # Get required fields and construct Jekyll compatible name.
        title = post[:Title]
        slug = post[:url_title]
        date = post[:Posted]
        content = post[:Body]

        name = [date.strftime("%Y-%m-%d"), slug].join('-') + ".textile"
        
        
        if process_images
          content.gsub!(TXP_TAG) do |tag_match|
            tag = $1
            tag_name = tag.split(' ')[0]
            case tag_name
            when 'image'
                thumb = false
            when 'thumbnail'
                thumb = true
            when 'article-image'
                thumb = false # default for this tag
                if tag =~ /thumbnail\s*=\s*(\d)/
                  if $1 == '1'
                    thumb = true
                  end
                end
            else
                next tag_match
            end
            # Simple attribute parser.  After getting rid of the initial tag name, it splits on =" , and then again on the endquote plus space to take everything in quotes (the attribute value) and everything outside the quotes (the attribute label). 
            # May fail on  = or " character within the attributes. Hope you don't have any with that. 
            tag_attrib_str = tag.sub(tag_name,'').lstrip  
            tag_attribs = Hash[*(tag_attrib_str.split(/\s*=\s*"/).map {|x| x.split(/"\s+/)}.flatten)]
            
            # Get the database info on the image 
            image = ''
            if tag_attribs.keys.include?("id") 
              db[IMG_QUERY].each do |h|
                if not (h.select {|k,v| k == :id && v == tag_attribs["id"].to_i}).empty?
                  image = h
                end
              end                     
            else
              if tag_attribs.keys.include?("name")
                db[IMG_QUERY].each do |h|
                  if not (h.select {|k,v| k == :name && v == tag_attribs["name"]}).empty?
                    image = h
                  end
                end         
              end
            end
            
            # Convert recognized txp tags with valid images to straight-up HTML img tags. Also move the images from the Textpattern directory to one for the site.
            if image == ''
              $stdout.puts "Failed to parse image tag:#{tag}"
              tag_match
            else
              # Add new tag details
              img_attribs = tag_attribs.reject {|key,val| IGNORED_TXP_ATTRIBS.include?(key)}
              if image[:alt] 
                img_attribs["alt"] ||= image[:alt]
              end
              if image[:caption]                      
                img_attribs["title"] ||= image[:caption]
              end
              
              img_source = image[:id].to_s + (thumb ? 't' : '') + image[:ext]
              img_filename = image[:name].sub('.',thumb ? '_t.' : '.')
              img_tag = convert_image(image_dir,img_source,IMG_DEST,img_filename,img_attribs)
              # Replace in text if it worked
              img_tag ? img_tag : tag_match
            end
          end
        end          

        # Get the relevant fields as a hash, delete empty fields and convert
        # to YAML for the header.
        data = {
           'layout' => 'post',
           'title' => title.to_s,
           'tags' => post[:Keywords].split(',')
         }.delete_if { |k,v| v.nil? || v == ''}.to_yaml

        # Write out the data and content to file.
        File.open(POST_DEST + "/#{name}", "w") do |f|
          f.puts data
          f.puts "---"
          f.puts content
        end
      end
    end
    
    private
    
    # Copies files (if possible) and returns the new img tag
    def self.convert_image(source_dir,source_name,dest_dir,dest_name,attrs={})
    
        source_file = File.join(source_dir, source_name)
        if not File.exist?(source_file)
            $stderr.puts "Could not locate image file:#{source_file}"
            return nil
        end
        dest_file = File.join(dest_dir,dest_name)
        
        # Copy & rename
        FileUtils.cp(source_file, dest_file)
        
        # Create img tag
        image_url = IMG_BASE_URL + dest_file
        tag = '<img src="'+image_url+'" '
        attrs.each do |name,val|
            tag << name + '="' + val + '" '
        end
        tag << '/>'
        
        return tag
    end
    
  end
end
